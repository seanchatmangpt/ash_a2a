# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ApproveWireCrosscheckTest do
  # Two proofs for the approver "approve" wire op, neither using a stand-in listener:
  #
  #   1. Byte identity: `AshA2A.C2.ApproveClient` and `scripts/approver_wire_reference.py`
  #      (an independent implementation of what `sa2a-approver approve` puts on the wire)
  #      produce identical pre-signature bytes, envelope bytes and request-frame bytes for the
  #      same inputs, and an Elixir verifier accepts a Python-made signature.
  #   2. `ApproveClient.submit/5` against the REAL `AuthorityService.Listener` (started as a
  #      separate `mix run` in authority_service/ with MIX_ENV=test, see
  #      sa2a-approver/scripts/authority_listener_harness.exs) over a unix socket and over
  #      mutual TLS (RSA test certs; ECDSA test certs fail the TLS 1.3 handshake on this OTP).
  #
  # Needs python3 with `cryptography` (pip install cryptography) and a compiled
  # authority_service (cd authority_service && MIX_ENV=test mix deps.get && mix compile).
  use ExUnit.Case, async: false

  alias AshA2A.C2.ApproveClient
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, SignedMessage}

  @moduletag :serial
  @moduletag timeout: 300_000

  @root Path.expand("../../..", __DIR__)
  @reference Path.join(@root, "scripts/approver_wire_reference.py")
  @harness Path.join(@root, "sa2a-approver/scripts/authority_listener_harness.exs")

  defp b64u(b), do: Base.url_encode64(b, padding: false)
  defp unb64u(s), do: Base.url_decode64!(s, padding: false)

  defp key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{pub: pub, priv: priv, kid: KeyRef.kid!("ES256", pub)}
  end

  defp fields(k, digest, over \\ %{}) do
    now = System.os_time(:second)

    Map.merge(
      %{
        "v" => 1,
        "alg" => "ES256",
        "kid" => k.kid,
        "effect_digest" => digest,
        "principal" => "agent:alice",
        "policy_epoch" => 3,
        "revocation_epoch" => 4,
        "generation" => 9,
        "nonce" => b64u(:crypto.strong_rand_bytes(12)),
        "not_before" => now - 10,
        "expires" => now + 200,
        "audience" => "authority:test"
      },
      over
    )
  end

  defp digest(bytes), do: SignedMessage.digest(bytes)

  # The wire approval `%{"envelope" => map, "message" => b64u}` Elixir-side.
  defp approval(k, fields) do
    {:ok, bytes} = SignedMessage.build(fields)
    sig = :crypto.sign(:ecdsa, :sha256, bytes, [k.priv, :secp256r1])
    {approval_with(fields, bytes, sig), bytes, sig}
  end

  defp approval_with(fields, bytes, sig) do
    env = %Envelope{
      v: fields["v"],
      alg: "ES256",
      kid: fields["kid"],
      profile: :classical,
      signed_bytes_digest: digest(bytes),
      signature: sig,
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: fields["audience"]
    }

    {:ok, json} = Envelope.encode(env)
    %{"envelope" => Jason.decode!(json), "message" => b64u(bytes)}
  end

  defp python(args, stdin) do
    py = System.find_executable("python3") || flunk("python3 not found")

    {out, 0} =
      System.cmd(
        "sh",
        ["-c", "printf %s \"$0\" | #{py} -I #{@reference} #{args}", stdin],
        stderr_to_stdout: true
      )

    out
  end

  defp pem_private(k) do
    # SEC1 ECPrivateKey for secp256r1.
    rec =
      {:ECPrivateKey, 1, k.priv, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, k.pub, :asn1_NOVALUE}

    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, rec)])
  end

  describe "byte identity with the Python reference" do
    setup do
      assert {_, 0} = System.cmd("python3", ["-c", "import cryptography"], stderr_to_stdout: true)
      :ok
    end

    test "pre-signature bytes, envelope and request frame are byte-identical" do
      k = key()

      eff =
        ~s({"capability":"deploy.release","inputs":{"env":"prod","replicas":3},"target":"svc/payments"})

      f = fields(k, digest(eff), %{"nonce" => "fixed-nonce-0001"})
      {approval, bytes, sig} = approval(k, f)

      {:ok, env_json} =
        Envelope.encode(%Envelope{
          v: 1,
          alg: "ES256",
          kid: k.kid,
          profile: :classical,
          signed_bytes_digest: digest(bytes),
          signature: sig,
          nonce: f["nonce"],
          not_before: f["not_before"],
          expires: f["expires"],
          audience: f["audience"]
        })

      # What ApproveClient actually puts on the wire, captured by a plain socket peer.
      path = Path.join(System.tmp_dir!(), "awc-#{System.unique_integer([:positive])}.sock")
      File.rm(path)

      {:ok, l} =
        :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, String.to_charlist(path)}}, active: false])

      parent = self()

      spawn_link(fn ->
        {:ok, s} = :gen_tcp.accept(l, 5_000)
        {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, 5_000)
        {:ok, body} = :gen_tcp.recv(s, len, 5_000)
        send(parent, {:body, body})
        out = ~s({"ok":true})
        :gen_tcp.send(s, <<byte_size(out)::32, out::binary>>)
        :gen_tcp.close(s)
      end)

      on_exit(fn -> File.rm(path) end)

      assert :ok =
               ApproveClient.submit(
                 %{authority_socket: path},
                 "alice",
                 f["effect_digest"],
                 9,
                 approval
               )

      assert_receive {:body, elixir_body}

      req = Jason.encode!(%{"fields" => f, "approver" => "alice", "signature_b64u" => b64u(sig)})
      py = Jason.decode!(python("build", req))

      assert unb64u(py["message_b64u"]) == bytes
      assert unb64u(py["envelope_b64u"]) == env_json
      assert unb64u(py["body_b64u"]) == elixir_body
      assert b64u(sig) == py["signature_b64u"]
    end

    test "a Python-made signature verifies in the Elixir verifier and its request is accepted shape" do
      k = key()
      f = fields(k, digest("e"))

      req =
        Jason.encode!(%{
          "fields" => f,
          "approver" => "alice",
          "private_key_pem" => pem_private(k)
        })

      py = Jason.decode!(python("build", req))
      bytes = unb64u(py["message_b64u"])
      assert {:ok, ^bytes} = SignedMessage.build(f)

      record = %KeyRecord{
        kid: k.kid,
        alg: "ES256",
        public_key: k.pub,
        custodian_id: "alice",
        custody_tier: :i3,
        state: :active,
        revocation_epoch: 4
      }

      env = Jason.decode!(unb64u(py["envelope_b64u"]))
      {:ok, decoded} = Envelope.decode(unb64u(py["envelope_b64u"]))

      assert {:valid, %{custodian_id: "alice"}} =
               Sa2aCrypto.verify_envelope(
                 decoded,
                 bytes,
                 Sa2aCrypto.Registry.Static.view([record]),
                 audience: "authority:test",
                 required_profile: :classical
               )

      body = Jason.decode!(unb64u(py["body_b64u"]))

      assert %{
               "op" => "approve",
               "approver" => "alice",
               "generation" => 9,
               "approval" => %{"envelope" => ^env}
             } = body
    end
  end

  describe "ApproveClient against the real AuthorityService.Listener" do
    setup do
      assert {_, 0} = System.cmd("python3", ["-c", "import cryptography"], stderr_to_stdout: true)
      work = Path.join(System.tmp_dir!(), "awx-#{System.unique_integer([:positive])}")
      File.mkdir_p!(work)
      keys = %{"alice" => key(), "bob" => key(), "carol" => key()}
      tls = tls_files(work)

      cfg = %{
        dir: work,
        approvers: Map.new(keys, fn {n, k} -> {n, Base.encode16(k.pub, case: :lower)} end),
        tls: tls.server
      }

      File.write!(Path.join(work, "config.json"), Jason.encode!(cfg))
      mix = System.find_executable("mix") || flunk("mix not found")

      port =
        Port.open({:spawn_executable, mix}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          cd: Path.join(@root, "authority_service"),
          args: ["run", "--no-halt", @harness],
          env: [
            {~c"MIX_ENV", ~c"test"},
            {~c"APPROVER_HARNESS_CONFIG", String.to_charlist(Path.join(work, "config.json"))}
          ]
        ])

      on_exit(fn ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", [Integer.to_string(pid)])
          _ -> :ok
        end

        File.rm_rf(work)
      end)

      ready = Path.join(work, "ready.json")
      ready_info = await_ready(ready, port, 240_000)
      {:ok, keys: keys, ready: ready_info, tls_client: tls.client}
    end

    defp await_ready(path, port, left) when left > 0 do
      case File.read(path) do
        {:ok, s} ->
          Jason.decode!(s)

        _ ->
          receive do
            {^port, {:exit_status, st}} -> flunk("authority listener exited #{st}")
            {^port, {:data, _}} -> await_ready(path, port, left)
          after
            500 -> await_ready(path, port, left - 500)
          end
      end
    end

    defp await_ready(_, _, _), do: flunk("authority listener did not start")

    defp tls_files(work) do
      rsa = fn -> [key: :public_key.generate_key({:rsa, 2048, 65_537})] end
      san = [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]

      %{server_config: sc, client_config: cc} =
        :public_key.pkix_test_data(%{
          server_chain: %{root: rsa.(), intermediates: [], peer: rsa.() ++ [extensions: san]},
          client_chain: %{root: rsa.(), intermediates: [], peer: rsa.()}
        })

      pem = fn type, ders ->
        :public_key.pem_encode(for d <- ders, do: {type, d, :not_encrypted})
      end

      {ktype, kder} = sc[:key]
      f = &Path.join(work, &1)
      File.write!(f.("srv.crt"), pem.(:Certificate, [sc[:cert]]))
      File.write!(f.("srv.key"), pem.(ktype, [kder]))
      File.write!(f.("srv.ca"), pem.(:Certificate, sc[:cacerts]))

      %{
        server: %{certfile: f.("srv.crt"), keyfile: f.("srv.key"), cacertfile: f.("srv.ca")},
        client: %{host: "localhost", cacerts: cc[:cacerts], cert: cc[:cert], key: cc[:key]}
      }
    end

    defp submit(ctx, who, k, f) do
      {approval, _, _} = approval(k, f)
      ApproveClient.submit(ctx, who, f["effect_digest"], f["generation"], approval)
    end

    test "unix socket: accepted, then every refusal", %{keys: keys, ready: ready} do
      ctx = %{authority_socket: ready["sock"]}
      d = digest("effect-uds")
      alice = keys["alice"]
      f = fields(alice, d)

      assert :ok = submit(ctx, "alice", alice, f)
      # same slot again
      assert {:error, {:refused, "duplicate_approval"}} =
               submit(ctx, "alice", alice, fields(alice, d))

      # same (kid, nonce) on another slot
      assert {:error, {:refused, "duplicate_approval"}} =
               submit(
                 ctx,
                 "alice",
                 alice,
                 fields(alice, d, %{"generation" => 10, "nonce" => f["nonce"]})
               )

      # wrong signer: bob's approval in alice's slot, and the reverse
      assert {:error, {:refused, "approval_invalid"}} =
               submit(ctx, "carol", keys["bob"], fields(keys["bob"], d))

      # malformed approvals
      assert {:error, {:refused, "malformed_approval"}} =
               ApproveClient.submit(ctx, "carol", d, 9, %{"envelope" => "x", "message" => "AAAA"})

      assert {:error, {:refused, "malformed_approval"}} =
               ApproveClient.submit(ctx, "carol", d, 9, %{"envelope" => %{}, "message" => "AAAA"})

      # tampered signature
      carol = keys["carol"]
      fc = fields(carol, d)
      {a, bytes, sig} = approval(carol, fc)

      bad =
        approval_with(
          fc,
          bytes,
          binary_part(sig, 0, byte_size(sig) - 1) <> <<Bitwise.bxor(:binary.last(sig), 1)>>
        )

      assert {:error, {:refused, "approval_invalid"}} =
               ApproveClient.submit(ctx, "carol", d, 9, bad)

      # the untampered one is still accepted: refusals consumed no slot or nonce
      assert :ok = ApproveClient.submit(ctx, "carol", d, 9, a)
    end

    test "mutual TLS: accepted and refused over the same real listener",
         %{keys: keys, ready: ready, tls_client: tls} do
      ctx = %{c2_tls: Map.put(tls, :port, ready["tls_port"]), authority_socket: "/nonexistent"}
      d = digest("effect-tls")
      bob = keys["bob"]

      assert :ok = submit(ctx, "bob", bob, fields(bob, d))
      assert {:error, {:refused, "duplicate_approval"}} = submit(ctx, "bob", bob, fields(bob, d))

      assert {:error, {:refused, "approval_invalid"}} =
               submit(ctx, "alice", bob, fields(bob, d))

      # a client with no valid certificate or a wrong pinned CA never reaches the op
      odir = Path.join(System.tmp_dir!(), "awx-other-#{System.unique_integer([:positive])}")
      File.mkdir_p!(odir)
      on_exit(fn -> File.rm_rf(odir) end)
      other = tls_files(odir).client
      wrong = Map.merge(ctx, %{c2_tls: Map.merge(ctx.c2_tls, %{cacerts: other.cacerts})})
      assert {:error, :authority_transport_refused} = submit(wrong, "bob", bob, fields(bob, d))
      no_cert = %{ctx | c2_tls: Map.merge(ctx.c2_tls, %{cert: other.cert, key: other.key})}

      assert {:error, :authority_transport_refused} =
               submit(no_cert, "alice", keys["alice"], fields(keys["alice"], d))
    end
  end
end
