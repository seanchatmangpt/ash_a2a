defmodule AshA2A.C2.FramedInteropTest do
  @moduledoc """
  Interop court (docs/reference/c2-wire-interop.md): the control plane's framed clients drive
  the REAL `authority_service` and `actuator` releases, each a separate OS process started
  through its production entrypoint (`MIX_ENV=prod mix run --no-halt`), over unix sockets.

  Chicago style, no doubles: the authority process signs with its own key file, the actuator
  process verifies against its own pinned registry, executes the real `ledger_append` effector
  and appends to its real hash-chained ledger; the assertions read that ledger from disk
  (`C2Harness.Oracle`) and the authority's issuance journal. Hosting scope: same host, same uid,
  no Erlang distribution (`-start_epmd false`, `RELEASE_DISTRIBUTION=none`).

  Chain under test:
  `PreparedEffect -> ActuationPipeline -> AuthorityClient.Framed -> authority process
  -> canonical Certificate -> ActuatorClient.Framed -> actuator process -> ledger entry`.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  @moduletag :c2_interop
  @moduletag timeout: 600_000

  alias AshA2A.C2.{
    ActuationPipeline,
    ActuatorClient,
    ActuatorProfile,
    AuthorityClient,
    Certificate,
    CertificateVerifier,
    PreparedEffect
  }

  alias C2Harness.{Fleet, Oracle, Proc, Wire}
  alias Sa2aCrypto.{KeyRecord, KeyRef, Registry.Static}

  @audience "actuator:interop"
  @authority_audience "authority:interop"
  @subject "subject:orders/42"
  @support Path.expand("../../support/c2_harness", __DIR__)

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "c2-interop-" <> Base.url_encode64(:crypto.strong_rand_bytes(5), padding: false)
      )

    dirs = for d <- ~w(act auth sock), into: %{}, do: {d, Path.join(root, d)}
    for {_, d} <- dirs, do: File.mkdir_p!(d)
    for d <- ~w(act auth), do: File.chmod!(dirs[d], 0o700)
    state_dir = Path.join(dirs["act"], "state")
    File.mkdir_p!(state_dir)
    build_root = Fleet.default_build_root()
    build!(build_root)

    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    kid = KeyRef.kid!("ES256", pub)
    b64 = &Base.url_encode64(&1, padding: false)

    write!(Path.join([dirs["auth"], "key", "policy.key"]), b64.(priv), 0o600)

    write!(
      Path.join([dirs["auth"], "policy", "policy.json"]),
      Jason.encode!(%{
        "epoch" => 3,
        "approvers" => [],
        "min_approver_tier" => "i3",
        "classes" => %{
          "internal_append" => [%{"max_amount" => "infinity", "k" => 0}],
          "none" => [%{"max_amount" => "infinity", "k" => 0}]
        }
      }),
      0o600
    )

    write!(Path.join([dirs["auth"], "policy", "approvers.json"]), "[]", 0o600)

    act_sock = Path.join(dirs["sock"], "act.sock")
    auth_sock = Path.join(dirs["sock"], "auth.sock")
    cfg = Path.join(dirs["act"], "config.json")

    write!(
      cfg,
      Jason.encode!(%{
        "state_dir" => state_dir,
        "audience" => @audience,
        "policy_epoch" => 3,
        "allowed_subjects" => [@subject],
        "quorum" => %{"internal_append" => 1, "none" => 1},
        "quorum_default" => 1,
        "registry" => [
          %{
            "kid" => kid,
            "alg" => "ES256",
            "public_key" => b64.(pub),
            "custodian_id" => "authority-service",
            "custody_tier" => "i2",
            "state" => "active",
            "revocation_epoch" => 0
          }
        ],
        "wire" => %{"uds_path" => act_sock}
      }),
      0o600
    )

    write!(
      Path.join(state_dir, "revocation.json"),
      Jason.encode!(%{"refreshed_at" => System.os_time(:second), "epoch" => 0, "revoked" => []}),
      0o600
    )

    env = fn mix_env, br ->
      [
        {"MIX_ENV", mix_env},
        {"MIX_BUILD_ROOT", br},
        {"ERL_FLAGS", "-start_epmd false"},
        {"RELEASE_DISTRIBUTION", "none"},
        {"C2_PARENT_PID", System.pid()}
      ]
    end

    logs = Path.join(root, "logs")

    {:ok, authority} =
      Proc.start("authority", Path.join(Fleet.repo_root(), "authority_service"),
        script: Path.join(@support, "watchdog.exs"),
        log: Path.join(logs, "authority.log"),
        env:
          env.("prod", Path.join(build_root, "authority-prod")) ++
            [
              {"AUTHORITY_KEY_FILE", Path.join([dirs["auth"], "key", "policy.key"])},
              {"AUTHORITY_CONFIG_DIR", dirs["auth"]},
              {"AUTHORITY_LISTEN_UNIX", auth_sock},
              {"AUTHORITY_AUDIENCE", @authority_audience},
              {"AUTHORITY_JOURNAL", Path.join(dirs["auth"], "journal.log")}
            ],
        ready:
          {:poll,
           fn ->
             match?(
               {:ok, %{"refusal" => "unknown_op"}},
               Wire.lp(auth_sock, %{"op" => "probe"}, 2_000)
             )
           end}
      )

    {:ok, actuator} =
      Proc.start("actuator", Path.join(Fleet.repo_root(), "actuator"),
        script: Path.join(@support, "watchdog.exs"),
        log: Path.join(logs, "actuator.log"),
        env: env.("prod", Path.join(build_root, "actuator-prod")) ++ [{"ACTUATOR_CONFIG", cfg}],
        timeout: 60_000,
        ready:
          {:poll,
           fn ->
             match?({:ok, %{"ok" => true}}, Wire.uds(act_sock, ~s({"op":"health"}), 1_000))
           end}
      )

    on_exit(fn ->
      Proc.stop(actuator)
      Proc.stop(authority)
      File.rm_rf(root)
    end)

    record = %KeyRecord{
      kid: kid,
      alg: "ES256",
      public_key: pub,
      custodian_id: "authority-service",
      custody_tier: :i2,
      state: :active,
      revocation_epoch: 0
    }

    {:ok,
     ctx: %{
       policy_epoch: 3,
       revocation_epoch: 0,
       generation: 1,
       audience: @audience,
       authority_socket: auth_sock,
       actuator_socket: act_sock
     },
     state_dir: state_dir,
     auth_journal: Path.join(dirs["auth"], "journal.log"),
     registry: Static.view([record])}
  end

  defp build!(build_root) do
    for {proj, name} <- [{"authority_service", "authority-prod"}, {"actuator", "actuator-prod"}] do
      {out, code} =
        System.cmd("mix", ["compile"],
          cd: Path.join(Fleet.repo_root(), proj),
          env: [{"MIX_ENV", "prod"}, {"MIX_BUILD_ROOT", Path.join(build_root, name)}],
          stderr_to_stdout: true
        )

      if code != 0, do: raise("child build failed #{proj}: #{String.slice(out, -1500, 1500)}")
    end
  end

  defp write!(path, data, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
    File.chmod!(path, mode)
  end

  defp effect(entry) do
    id = "ei:interop-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    PreparedEffect.new("agent:alice", "actuator.ledger.append", @subject, %{
      effect_type: "ledger_append",
      consequence_class: "internal_append",
      effect_instance_id: id,
      resource_bounds: %{max_bytes: 256},
      params: %{entry: entry}
    })
  end

  defp run(effect, ctx),
    do: ActuationPipeline.execute(effect, ctx, AuthorityClient.Framed, ActuatorClient.Framed)

  defp entries(state_dir) do
    assert {:ok, list} = Oracle.ledger(state_dir)
    list
  end

  test "full pipeline: prepared effect -> authority issue -> actuator execute -> ledger entry",
       %{ctx: ctx, state_dir: sd, auth_journal: aj} do
    before = length(entries(sd))
    e = effect("interop-full")
    {:ok, ae} = ActuatorProfile.effect(e, ctx.policy_epoch)

    assert {:ok, %{"state" => "executed", "status" => "performed", "effect_digest" => d}} =
             run(e, ctx)

    assert d == ae.digest

    after_entries = entries(sd)
    assert length(after_entries) == before + 1
    last = List.last(after_entries)
    assert last["effect_digest"] == ae.digest
    assert last["entry"] == "interop-full"

    assert {:ok, bodies} = Oracle.journal(aj)
    assert Enum.count(bodies, &(&1["effect_digest"] == ae.digest)) == 1
  end

  test "a certificate the authority process issued verifies through CertificateVerifier (ms struct, seconds message)",
       %{ctx: ctx, registry: registry} do
    e = effect("interop-verify")
    {:ok, ae} = ActuatorProfile.effect(e, ctx.policy_epoch)

    assert {:ok, %{decision: :admit, certificate: %Certificate{} = cert}} =
             AuthorityClient.authorize(
               AuthorityClient.Framed,
               AshA2A.C2.AuthorityRequest.new(e, ctx),
               ctx
             )

    assert cert.effect_digest == ae.digest
    assert rem(cert.not_before_ms, 1000) == 0 and rem(cert.expires_at_ms, 1000) == 0
    assert cert.expires_at_ms > cert.not_before_ms

    # identity in the actuator profile is the actuator digest (docs/reference/c2-wire-interop.md)
    identity = %{digest: ae.digest, principal: e.principal}

    vctx = %{
      policy_epoch: 3,
      revocation_epoch: 0,
      generation: 1,
      principal: e.principal,
      registry: registry,
      audience: @audience,
      now: System.os_time(:second)
    }

    assert :ok = CertificateVerifier.verify(cert, identity, vctx)

    forged = %{
      cert
      | signatures: Enum.map(cert.signatures, &%{&1 | signature: :binary.copy(<<0>>, 64)})
    }

    assert {:error, :certificate_refused} = CertificateVerifier.verify(forged, identity, vctx)
  end

  test "the same effect is issued once; a replayed certificate returns evidence, not a second entry",
       %{ctx: ctx, state_dir: sd} do
    e = effect("interop-once")
    request = AshA2A.C2.AuthorityRequest.new(e, ctx)

    assert {:ok, %{decision: :admit, certificate: cert}} =
             AuthorityClient.authorize(AuthorityClient.Framed, request, ctx)

    assert {:ok, %{"status" => "performed"}} =
             ActuatorClient.execute(ActuatorClient.Framed, e, cert, ctx)

    n = length(entries(sd))

    assert {:ok, %{"status" => "replayed"}} =
             ActuatorClient.execute(ActuatorClient.Framed, e, cert, ctx)

    assert length(entries(sd)) == n

    assert {:error, {:authority_refused, "already_issued"}} = run(e, ctx)
    assert length(entries(sd)) == n
  end

  test "the control plane cannot swap the effect or forge a signature: nothing reaches the ledger",
       %{ctx: ctx, state_dir: sd} do
    e = effect("interop-a")
    other = effect("interop-b")
    request = AshA2A.C2.AuthorityRequest.new(e, ctx)

    assert {:ok, %{certificate: cert}} =
             AuthorityClient.authorize(AuthorityClient.Framed, request, ctx)

    n = length(entries(sd))

    # client-side digest binding: certificate for `e` cannot carry `other`
    assert {:error, :effect_digest_mismatch} =
             ActuatorClient.execute(ActuatorClient.Framed, other, cert, ctx)

    # the actuator itself refuses a flipped signature bit
    [s] = cert.signatures
    sz = byte_size(s.signature) - 1
    <<head::binary-size(^sz), last>> = s.signature
    bad = %{cert | signatures: [%{s | signature: head <> <<Bitwise.bxor(last, 1)>>}]}

    assert {:error, {:actuator_refused, code}} =
             ActuatorClient.execute(ActuatorClient.Framed, e, bad, ctx)

    assert is_binary(code)

    # an actuator refusal for a subject outside its allow-list
    off =
      PreparedEffect.new("agent:alice", "actuator.ledger.append", "subject:elsewhere", e.payload)

    assert {:error, {:actuator_refused, "subject_not_allowed"}} = run(off, ctx)

    assert length(entries(sd)) == n
  end
end
