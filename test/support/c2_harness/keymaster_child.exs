# C2 compromise court: the KEYMASTER (court-side trust roots), a separate OS process.
#
# Run as `cd authority_service && MIX_ENV=test mix run --no-halt ... <this file>`.
# It is the only process that ever holds private key material other than the two
# credentials the threat model deliberately hands the attacker (signer keys "A"/"A2" of
# custodian custA and approver "alice": "compromise of fewer than k signers"). The test
# process (which plays the control-plane node and runs the attacker) receives ONLY public
# keys, file paths of its own client credentials, and signed artifacts.
#
# What it does:
#   * generates every key (actuation signers A, A2 [same custodian], B, C; approvers alice,
#     bob, carol; the real AuthorityService policy key; the actuator/control-plane PKI)
#   * writes the operator-side files each real service reads (authority key file 0600,
#     policy.json, approvers.json; actuator TLS server material) into the given dirs
#   * signs on request over a length-prefixed JSON UDS:
#       issue_actuation  actuation certificate in the ACTUATOR's wire form. journal=true is
#                        an intended issuance (fsync'd into the hash-chained issuance
#                        journal BEFORE signing, (digest, generation) issued at most once,
#                        like AuthorityService.Issuer); journal=false is a MIS-ISSUANCE
#                        (authority defect / mis-signed artifact) that is NOT journaled, so
#                        any ledger entry it causes is unauthorized by definition.
#       approve          a human approval in the real AuthorityService wire form
#       compromise       hands over ONLY A, A2, alice
#
# Why a stand-in issuer for actuator-shaped effects: the real AuthorityService parses
# effects with `effect_class`/`amount` keys while the Actuator requires an exact key set
# without them, so the real service cannot issue a certificate the actuator accepts
# (recorded by the court as an integration handoff, see the report `compat` section).
alias Sa2aCrypto.{Envelope, KeyRef, SignedMessage}

defmodule Km do
  def b64(bin), do: Base.url_encode64(bin, padding: false)
  def b64d(s) when is_binary(s), do: Base.url_decode64(s, padding: false)
  def b64d(_), do: :error
  def now, do: System.os_time(:second)

  def key(name, custodian, tier, rev_epoch) do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)

    %{
      name: name,
      pub: pub,
      priv: priv,
      kid: KeyRef.kid!("ES256", pub),
      custodian: custodian,
      tier: tier,
      rev_epoch: rev_epoch
    }
  end

  def public(k) do
    %{
      "name" => k.name,
      "kid" => k.kid,
      "alg" => "ES256",
      "public_key" => b64(k.pub),
      "custodian_id" => k.custodian,
      "custody_tier" => Atom.to_string(k.tier),
      "state" => "active",
      "revocation_epoch" => k.rev_epoch
    }
  end

  def sign(k, msg), do: :crypto.sign(:ecdsa, :sha256, msg, [k.priv, :secp256r1])

  def pem_cert(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  def write!(path, data, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    File.chmod!(path, mode)
  end

  def frame_loop(sock, state_pid) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, bin} ->
        reply = GenServer.call(state_pid, {:req, bin}, 30_000)
        :ok = :gen_tcp.send(sock, reply)
        frame_loop(sock, state_pid)

      _ ->
        :gen_tcp.close(sock)
    end
  end
end

defmodule Km.Server do
  use GenServer
  alias AuthorityService.Journal

  # `:raw` journal file handles are usable only by the opening process: open it HERE
  def init(%{journal_path: path} = st) do
    {:ok, journal} = AuthorityService.Journal.open(path)
    {:ok, st |> Map.delete(:journal_path) |> Map.put(:journal, journal)}
  end

  def handle_call({:req, bin}, _from, st) do
    {reply, st} =
      case Jason.decode(bin) do
        {:ok, %{"op" => op} = req} -> handle(op, req, st)
        _ -> {%{"ok" => false, "refusal" => "malformed_request"}, st}
      end

    {:reply, Jason.encode!(reply), st}
  rescue
    e -> {:reply, Jason.encode!(%{"ok" => false, "refusal" => "keymaster_error", "detail" => Exception.message(e)}), st}
  end

  defp handle("hello", _req, st) do
    reg = fn ks -> Enum.map(ks, &Km.public/1) end

    {%{
       "ok" => true,
       "os_pid" => System.pid(),
       "node_alive" => Node.alive?(),
       "signers" => reg.(Map.values(st.signers)),
       "approvers" => reg.(Map.values(st.approvers)),
       "svc" => %{"kid" => st.svc.kid, "public_key" => Km.b64(st.svc.pub)}
     }, st}
  end

  defp handle("compromise", %{"name" => name}, st) do
    cond do
      name in ["A", "A2"] -> {%{"ok" => true, "private_key" => Km.b64(st.signers[name].priv), "kid" => st.signers[name].kid}, st}
      name == "alice" -> {%{"ok" => true, "private_key" => Km.b64(st.approvers[name].priv), "kid" => st.approvers[name].kid}, st}
      true -> {%{"ok" => false, "refusal" => "not_compromisable"}, st}
    end
  end

  defp handle("scan", req, st) do
    granted = ["A", "A2", "alice"]

    keys =
      Enum.reject(Map.to_list(st.signers) ++ Map.to_list(st.approvers) ++ [{"svc", st.svc}], fn {n, _} -> n in granted end)

    forms = fn bin -> [bin, Km.b64(bin), Base.encode64(bin), Base.encode16(bin, case: :lower), Base.encode16(bin, case: :upper)] end

    needles =
      Enum.flat_map(keys, fn {n, k} -> Enum.map(forms.(k.priv), &{"key:" <> n, &1}) end) ++
        Enum.map(st.paths, fn {n, p} -> {"path:" <> n, p} end) ++
        Enum.flat_map(st.secret_files, fn {n, path} -> [{"file:" <> n, path}, {"file_content:" <> n, File.read!(path)}] end)

    hay =
      if req["selftest"] do
        # plant every secret the scan must be able to see (proves the scan can fire)
        Enum.map_join(needles, "\n", fn {_, v} -> v end)
      else
        Base.decode64!(req["haystack"])
      end

    leaks = for {name, needle} <- needles, needle != "", String.contains?(hay, needle), do: name |> String.split(":") |> Enum.take(2) |> Enum.join(":")
    {%{"ok" => true, "leaks" => Enum.uniq(leaks), "needles" => length(needles), "needle_names" => needles |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}, st}
  end

  defp handle("approve", req, st) do
    with %{} = k <- st.approvers[req["name"]] do
      now = Km.now()

      fields = %{
        "v" => 1,
        "alg" => "ES256",
        "kid" => k.kid,
        "effect_digest" => req["digest"],
        "principal" => req["principal"] || "agent:alice",
        "policy_epoch" => req["policy_epoch"] || 3,
        "revocation_epoch" => req["revocation_epoch"] || 4,
        "generation" => req["generation"] || 9,
        "nonce" => req["nonce"] || Km.b64(:crypto.strong_rand_bytes(12)),
        "not_before" => now + (req["not_before_off"] || -10),
        "expires" => now + (req["expires_off"] || 200),
        "audience" => req["audience"] || "authority:court"
      }

      {:ok, bytes} = SignedMessage.build(fields)

      env = %Envelope{
        v: 1,
        alg: "ES256",
        kid: k.kid,
        profile: :classical,
        signed_bytes_digest: SignedMessage.digest(bytes),
        signature: Km.sign(k, bytes),
        nonce: fields["nonce"],
        not_before: fields["not_before"],
        expires: fields["expires"],
        audience: fields["audience"]
      }

      {:ok, json} = Envelope.encode(env)

      {%{"ok" => true, "approval" => %{"envelope" => Jason.decode!(json), "message" => Km.b64(bytes)}}, st}
    else
      _ -> {%{"ok" => false, "refusal" => "unknown_approver"}, st}
    end
  end

  defp handle("issue_actuation", req, st) do
    with {:ok, eff} <- Km.b64d(req["effect"]),
         {:ok, emap} <- Jason.decode(eff),
         names when is_list(names) <- req["signers"] || ["A", "B"],
         true <- Enum.all?(names, &Map.has_key?(st.signers, &1)) do
      digest = req["digest"] || SignedMessage.digest(eff)
      gen = req["generation"] || 1
      journal? = Map.get(req, "journal", true)
      now = Km.now()

      nonce_prefix = req["nonce_prefix"] || Km.b64(:crypto.strong_rand_bytes(9))

      nonces =
        req["nonces"] ||
          names |> Enum.with_index() |> Enum.map(fn {_, i} -> "#{nonce_prefix}-#{i}" end)

      fields = %{
        "v" => req["v"] || 1,
        "effect_digest" => digest,
        "principal" => req["principal"] || emap["principal"],
        "policy_epoch" => req["policy_epoch"] || 3,
        "revocation_epoch" => req["revocation_epoch"] || 7,
        "generation" => gen,
        "not_before" => now + (req["not_before_off"] || -60),
        "expires" => now + (req["expires_off"] || 300),
        "audience" => req["audience"] || "actuator:court"
      }

      cond do
        journal? and Journal.issued?(st.journal, digest, gen) ->
          {%{"ok" => false, "refusal" => "already_issued"}, st}

        true ->
          entry = %{
            "cert_kid" => "keymaster:" <> Enum.join(names, "+"),
            "nonce" => hd(nonces),
            "effect_digest" => digest,
            "generation" => gen,
            "audience" => fields["audience"],
            "expires" => fields["expires"],
            "approvals" => [],
            "intended" => true,
            "instance" => emap["effect_instance_id"],
            "signers" => names
          }

          journaled =
            if journal?,
              do: Journal.append(st.journal, entry),
              else: {:ok, st.journal}

          case journaled do
            {:ok, j2} ->
              sigs =
                names
                |> Enum.zip(nonces)
                |> Enum.map(fn {n, nonce} ->
                  k = st.signers[n]
                  {:ok, msg} = SignedMessage.build(Map.merge(fields, %{"alg" => "ES256", "kid" => k.kid, "nonce" => nonce}))
                  %{"kid" => k.kid, "alg" => "ES256", "nonce" => nonce, "signature" => Km.b64(Km.sign(k, msg))}
                end)

              cert = Jcs.encode(Map.put(fields, "signatures", sigs))

              unless journal?,
                do: File.write!(st.misissue_log, Jason.encode!(%{"digest" => digest, "generation" => gen, "at" => now}) <> "\n", [:append])

              {%{"ok" => true, "certificate" => Km.b64(cert), "digest" => digest, "nonces" => nonces, "journaled" => journal?}, %{st | journal: j2}}

            {:error, reason} ->
              {%{"ok" => false, "refusal" => "journal_failed", "detail" => inspect(reason)}, st}
          end
      end
    else
      _ -> {%{"ok" => false, "refusal" => "malformed_request"}, st}
    end
  end

  defp handle(_, _, st), do: {%{"ok" => false, "refusal" => "unknown_op"}, st}
end

Code.eval_file(Path.join(__DIR__, "watchdog.exs"))
env = &System.fetch_env!/1
act_dir = env.("KM_ACT_DIR")
auth_dir = env.("KM_AUTH_DIR")
cp_dir = env.("KM_CP_DIR")
km_dir = env.("KM_DIR")
sock_path = env.("KM_SOCK")
actuator_audience = System.get_env("KM_ACTUATOR_AUDIENCE", "actuator:court")

signers =
  [
    Km.key("A", "custA", :i2, 7),
    Km.key("A2", "custA", :i2, 7),
    Km.key("B", "custB", :i2, 7),
    Km.key("C", "custC", :i2, 7)
  ]
  |> Map.new(&{&1.name, &1})

approvers =
  ["alice", "bob", "carol"]
  |> Enum.map(&Km.key(&1, &1, :i3, 4))
  |> Map.new(&{&1.name, &1})

svc = Km.key("svc", "authority-service", :i2, 0)

# --- real AuthorityService operator files (paths only are given to that service) --------
Km.write!(Path.join([auth_dir, "key", "policy.key"]), Km.b64(svc.priv), 0o600)

Km.write!(
  Path.join([auth_dir, "policy", "policy.json"]),
  Jason.encode!(%{
    "epoch" => 3,
    "approvers" => ["alice", "bob", "carol"],
    "min_approver_tier" => "i3",
    "classes" => %{
      "payment" => [
        %{"max_amount" => 10_000, "k" => 0},
        %{"max_amount" => 100_000, "k" => 1},
        %{"max_amount" => "infinity", "k" => 2}
      ]
    }
  }),
  0o600
)

Km.write!(
  Path.join([auth_dir, "policy", "approvers.json"]),
  Jason.encode!(Enum.map(Map.values(approvers), &Km.public/1)),
  0o600
)

# --- PKI: actuator mTLS server material (actuator side) + control-plane client material --
# P-256 keys + SHA-256 signatures: the OTP defaults are rejected by a TLS 1.3 handshake
# (measured on OTP 29.1.1), and the actuator listener is TLS 1.3 only
pki_opts = [key: {:namedCurve, :secp256r1}, digest: :sha256]

mk = fn ->
  :public_key.pkix_test_data(%{
    server_chain: %{root: pki_opts, intermediates: [], peer: pki_opts},
    client_chain: %{root: pki_opts, intermediates: [], peer: pki_opts}
  })
end

good = mk.()
rogue = mk.()

write_pair = fn dir, base, conf ->
  cert = conf[:cert]
  {ktype, kder} = conf[:key]
  Km.write!(Path.join(dir, base <> ".crt"), Km.pem_cert(cert), 0o644)
  Km.write!(Path.join(dir, base <> ".key"), :public_key.pem_encode([{ktype, kder, :not_encrypted}]), 0o600)
end

write_ca = fn path, ders -> Km.write!(path, Enum.map_join(ders, "", &Km.pem_cert/1), 0o644) end

# actuator server: its cert/key, and the CA that vouches for legitimate CLIENTS
write_pair.(Path.join(act_dir, "tls"), "server", good.server_config)
write_ca.(Path.join([act_dir, "tls", "client_ca.crt"]), good.server_config[:cacerts])
# control plane: its own legitimate client credential, the actuator's server CA (to verify it),
# and an attacker-generated credential that chains to a rogue root the actuator does not trust
write_pair.(cp_dir, "client", good.client_config)
write_ca.(Path.join(cp_dir, "server_ca.crt"), good.client_config[:cacerts])
write_pair.(cp_dir, "rogue_client", rogue.client_config)

# --- issuance journal (real AuthorityService.Journal format) ---------------------------
File.mkdir_p!(km_dir)
misissue_log = Path.join(km_dir, "misissued.jsonl")
File.write!(misissue_log, "")

{:ok, srv} =
  GenServer.start_link(Km.Server, %{
    signers: signers,
    approvers: approvers,
    svc: svc,
    journal_path: Path.join(km_dir, "issuance_journal.log"),
    misissue_log: misissue_log,
    actuator_audience: actuator_audience,
    paths: %{"act_dir" => act_dir, "auth_dir" => auth_dir, "km_dir" => km_dir},
    secret_files: %{
      "authority_key" => Path.join([auth_dir, "key", "policy.key"]),
      "actuator_tls_key" => Path.join([act_dir, "tls", "server.key"])
    }
  })

File.rm(sock_path)

{:ok, lsock} =
  :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, sock_path}}, {:packet, 4}, {:active, false}])

File.chmod!(sock_path, 0o600)

spawn_link(fn ->
  accept = fn accept ->
    case :gen_tcp.accept(lsock) do
      {:ok, s} ->
        pid = spawn(fn -> receive do :go -> Km.frame_loop(s, srv) end end)
        :ok = :gen_tcp.controlling_process(s, pid)
        send(pid, :go)
        accept.(accept)

      _ ->
        :ok
    end
  end

  accept.(accept)
end)

IO.puts("C2_READY " <> Jason.encode!(%{role: "keymaster", os_pid: System.pid(), node_alive: Node.alive?()}))
Process.sleep(:infinity)
