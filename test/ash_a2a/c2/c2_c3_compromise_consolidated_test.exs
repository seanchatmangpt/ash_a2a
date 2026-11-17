# NOTE: 1 module(s) removed from this consolidated file because the repaired originals (kept as separate files) define the same modules; see docs/reference/test-consolidation-merge.md.
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C2 & C3 Security, Wire & Compromise Courts (Worker 14)
# Contains 24 original test files:
#   - test/ash_a2a/c2/court_023_test.exs
#   - test/ash_a2a/c2/court_024_test.exs
#   - test/ash_a2a/c2/court_025_test.exs
#   - test/ash_a2a/c2/court_026_test.exs
#   - test/ash_a2a/c2/court_027_test.exs
#   - test/ash_a2a/c2/court_028_test.exs
#   - test/ash_a2a/c2/court_029_test.exs
#   - test/ash_a2a/c2/court_030_test.exs
#   - test/ash_a2a/c2/court_031_test.exs
#   - test/ash_a2a/c2/court_032_test.exs
#   - test/ash_a2a/c2/court_033_test.exs
#   - test/ash_a2a/c2/court_034_test.exs
#   - test/ash_a2a/c2/court_035_test.exs
#   - test/ash_a2a/c2/external_pipeline_test.exs
#   - test/ash_a2a/c2/framed_interop_test.exs
#   - test/ash_a2a/c2/mcp_projection_test.exs
#   - test/ash_a2a/c2/policy_evidence_test.exs
#   - test/ash_a2a/c2/prepared_effect_portable_digest_test.exs
#   - test/ash_a2a/c2/remote_endpoints_test.exs
#   - test/ash_a2a/c2/wire_contract_test.exs
#   - test/ash_a2a/c2_compromise/c2_compromise_court_test.exs
#   - test/ash_a2a/c2_compromise/catalog_integrity_test.exs
#   - test/ash_a2a/c2_compromise/oracle_test.exs
#   - test/ash_a2a/c3/signer_set_test.exs
# ==============================================================================

# ------------------------------------------------------------------------------
# Section 1: test/ash_a2a/c2/court_023_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C023Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 23 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-23", "capability", "subject", %{court: 23})
    b = AshA2A.C2.PreparedEffect.new("principal-23", "capability", "subject", %{court: 24})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 2: test/ash_a2a/c2/court_024_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C024Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 24 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-24", "capability", "subject", %{court: 24})
    b = AshA2A.C2.PreparedEffect.new("principal-24", "capability", "subject", %{court: 25})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 3: test/ash_a2a/c2/court_025_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C025Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 25 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-25", "capability", "subject", %{court: 25})
    b = AshA2A.C2.PreparedEffect.new("principal-25", "capability", "subject", %{court: 26})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 4: test/ash_a2a/c2/court_026_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C026Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 26 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-26", "capability", "subject", %{court: 26})
    b = AshA2A.C2.PreparedEffect.new("principal-26", "capability", "subject", %{court: 27})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 5: test/ash_a2a/c2/court_027_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C027Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 27 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-27", "capability", "subject", %{court: 27})
    b = AshA2A.C2.PreparedEffect.new("principal-27", "capability", "subject", %{court: 28})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 6: test/ash_a2a/c2/court_028_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C028Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 28 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-28", "capability", "subject", %{court: 28})
    b = AshA2A.C2.PreparedEffect.new("principal-28", "capability", "subject", %{court: 29})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 7: test/ash_a2a/c2/court_029_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C029Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 29 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-29", "capability", "subject", %{court: 29})
    b = AshA2A.C2.PreparedEffect.new("principal-29", "capability", "subject", %{court: 30})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 8: test/ash_a2a/c2/court_030_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C030Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 30 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-30", "capability", "subject", %{court: 30})
    b = AshA2A.C2.PreparedEffect.new("principal-30", "capability", "subject", %{court: 31})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 9: test/ash_a2a/c2/court_031_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C031Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 31 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-31", "capability", "subject", %{court: 31})
    b = AshA2A.C2.PreparedEffect.new("principal-31", "capability", "subject", %{court: 32})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 10: test/ash_a2a/c2/court_032_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C032Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 32 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-32", "capability", "subject", %{court: 32})
    b = AshA2A.C2.PreparedEffect.new("principal-32", "capability", "subject", %{court: 33})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 11: test/ash_a2a/c2/court_033_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C033Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 33 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-33", "capability", "subject", %{court: 33})
    b = AshA2A.C2.PreparedEffect.new("principal-33", "capability", "subject", %{court: 34})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 12: test/ash_a2a/c2/court_034_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C034Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 34 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-34", "capability", "subject", %{court: 34})
    b = AshA2A.C2.PreparedEffect.new("principal-34", "capability", "subject", %{court: 35})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 13: test/ash_a2a/c2/court_035_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C035Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 35 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-35", "capability", "subject", %{court: 35})
    b = AshA2A.C2.PreparedEffect.new("principal-35", "capability", "subject", %{court: 36})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 14: test/ash_a2a/c2/external_pipeline_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.ExternalPipelineTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{ActuationPipeline, AuthorityResponse, Certificate, PreparedEffect}

  defmodule Authority do
    @behaviour AshA2A.C2.AuthorityClient
    def authorize(request, _ctx) do
      cert = %Certificate{
        version: 1,
        effect_digest: request.effect_digest,
        principal: request.principal,
        policy_epoch: request.policy_epoch,
        revocation_epoch: request.revocation_epoch,
        generation: request.generation,
        nonce: "n1",
        not_before_ms: 0,
        expires_at_ms: 10_000,
        audience: request.audience,
        threshold: 1,
        signatures: [%{"key_id" => "external"}]
      }

      {:ok, AuthorityResponse.admit(cert)}
    end
  end

  defmodule Actuator do
    @behaviour AshA2A.C2.ActuatorClient
    def execute(effect, cert, _ctx) do
      send(self(), {:actuator_called, effect.digest, cert.effect_digest})
      {:ok, %{"state" => "executed", "effect_digest" => effect.digest}}
    end
  end

  test "protected pipeline crosses authority and actuator client boundaries" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})
    ctx = %{policy_epoch: 1, revocation_epoch: 2, generation: 3, audience: "actuator:payments"}

    assert {:ok, %{"state" => "executed"}} =
             ActuationPipeline.execute(effect, ctx, Authority, Actuator)

    assert_received {:actuator_called, effect_digest, certificate_digest}
    assert effect_digest == certificate_digest
  end
end

# ------------------------------------------------------------------------------
# Section 15: test/ash_a2a/c2/framed_interop_test.exs
# ------------------------------------------------------------------------------
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
              {"AUTHORITY_ACTUATOR_AUDIENCE", @audience},
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

# ------------------------------------------------------------------------------
# Section 16: test/ash_a2a/c2/mcp_projection_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.PolicyEvidence.McpProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.PolicyEvidence.McpProjection

  test "projects a tool call; digest changes with arguments" do
    {:ok, a} = McpProjection.project("alice", %{"name" => "pay", "arguments" => %{"n" => 1}})
    {:ok, b} = McpProjection.project("alice", %{"name" => "pay", "arguments" => %{"n" => 2}})
    assert a.capability == "mcp.tool:pay"
    assert a.principal == "alice"
    refute a.digest == b.digest
  end

  test "malformed calls are refused" do
    assert {:error, :mcp_tool_name_missing} = McpProjection.project("alice", %{})

    assert {:error, :mcp_arguments_malformed} =
             McpProjection.project("alice", %{"name" => "x", "arguments" => [1]})
  end
end

# ------------------------------------------------------------------------------
# Section 17: test/ash_a2a/c2/policy_evidence_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.PolicyEvidenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, PolicyEvidence, PreparedEffect}

  @pdp "https://pdp.example.com"
  @meta %{
    "policy_decision_point" => @pdp,
    "access_evaluation_endpoint" => "https://pdp.example.com/access/v1/evaluation",
    "x_vendor_extension" => %{"anything" => "ignored"}
  }

  defp request(overrides \\ %{}) do
    effect = PreparedEffect.new("alice", "wire.transfer", %{"acct" => "A1"}, %{"amount" => 5})

    ctx =
      Map.merge(
        %{policy_epoch: 3, revocation_epoch: 2, generation: 7, audience: "actuator://bank"},
        overrides
      )

    AuthorityRequest.new(effect, ctx)
  end

  test "allow becomes evidence bound to the exact effect, never DO authority" do
    r = request()
    assert {:ok, e} = PolicyEvidence.from_response(r, %{"decision" => true}, @pdp, @meta)
    assert e.decision == :allow
    assert PolicyEvidence.binds?(e, r)
    refute PolicyEvidence.grants_do_authority?(e)
  end

  test "evidence does not bind a different effect digest or stale fence" do
    {:ok, e} = PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, @meta)
    other = PreparedEffect.new("alice", "wire.transfer", %{"acct" => "A1"}, %{"amount" => 500})
    refute PolicyEvidence.binds?(e, %{request() | effect: other, effect_digest: other.digest})
    refute PolicyEvidence.binds?(e, request(%{generation: 8}))
    refute PolicyEvidence.binds?(e, request(%{policy_epoch: 4}))
  end

  test "PDP identifier mix-up is refused" do
    meta = Map.put(@meta, "policy_decision_point", "https://evil.example.com")

    assert {:error, :pdp_mismatch} =
             PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, meta)
  end

  test "non-HTTPS endpoint is refused; unknown metadata is ignored" do
    meta = Map.put(@meta, "access_evaluation_endpoint", "http://pdp.example.com/eval")

    assert {:error, :pdp_endpoint_not_https} =
             PolicyEvidence.from_response(request(), %{"decision" => true}, @pdp, meta)

    assert :ok = PolicyEvidence.validate_metadata(@meta, @pdp)
  end

  test "decision must be a JSON boolean" do
    for bad <- ["true", 1, nil] do
      assert {:error, :decision_malformed} =
               PolicyEvidence.from_response(request(), %{"decision" => bad}, @pdp, @meta)
    end

    assert {:ok, %{decision: :deny}} =
             PolicyEvidence.from_response(request(), %{"decision" => false}, @pdp, @meta)
  end

  test "SARC request carries digest, principal and fences" do
    r = request()
    assert {:ok, sarc} = PolicyEvidence.sarc_request(r)
    assert sarc["subject"]["id"] == "alice"
    assert sarc["action"]["name"] == "wire.transfer"
    assert sarc["resource"]["id"] == r.effect_digest
    assert sarc["context"]["generation"] == 7
  end
end

defmodule AshA2A.C2.PolicyEvidenceAdmissionTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, AuthorityService, PolicyEvidence, PreparedEffect}
  alias AshA2A.C2.PolicyEvidence.PdpClient

  defmodule Policy do
    def admit(_r, _c), do: :ok
    def issue(_r, _c), do: {:ok, :cert}
  end

  @pdp "https://pdp.example.com"
  @ctx %{policy_epoch: 1, revocation_epoch: 1, generation: 1, audience: "a"}

  defp request do
    AuthorityRequest.new(PreparedEffect.new("alice", "cap", %{}, %{}), @ctx)
  end

  defp stub(name, decision) do
    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/authzen-configuration" ->
          Req.Test.json(conn, %{
            "policy_decision_point" => @pdp,
            "access_evaluation_endpoint" => @pdp <> "/access/v1/evaluation"
          })

        _ ->
          Req.Test.json(conn, %{"decision" => decision})
      end
    end)
  end

  test "allow without evidence is refused when evidence is required" do
    ctx = Map.put(@ctx, :policy_evidence_required, true)

    assert {:ok, %{decision: :refuse, reason: :policy_evidence_missing}} =
             AuthorityService.authorize(Policy, request(), ctx)
  end

  test "bound allow evidence admits only through the authority" do
    stub(:allow, true)
    {:ok, e} = PdpClient.evidence(request(), @pdp, plug: {Req.Test, :allow})
    ctx = Map.merge(@ctx, %{policy_evidence_required: true, policy_evidence: e})
    assert {:ok, %{decision: :admit}} = AuthorityService.authorize(Policy, request(), ctx)
    refute PolicyEvidence.grants_do_authority?(e)
  end

  test "deny evidence is refused" do
    stub(:deny, false)
    {:ok, e} = PdpClient.evidence(request(), @pdp, plug: {Req.Test, :deny})
    ctx = Map.merge(@ctx, %{policy_evidence_required: true, policy_evidence: e})
    assert {:ok, %{decision: :refuse}} = AuthorityService.authorize(Policy, request(), ctx)
  end

  test "non-HTTPS PDP is refused before any request" do
    assert {:error, :pdp_not_https} = PdpClient.evidence(request(), "http://pdp.example.com")
  end
end

# ------------------------------------------------------------------------------
# Section 18: test/ash_a2a/c2/prepared_effect_portable_digest_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.PreparedEffectPortableDigestTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Identity.Canonical

  test "digest is JCS SHA-256 over the portable view" do
    effect =
      PreparedEffect.new(
        "principal:alice",
        :payments,
        %{"kind" => "order", "id" => 42},
        %{amount: 100, currency: "USD"}
      )

    assert {:ok, view} = PreparedEffect.portable_view(effect)
    assert {:ok, expected} = Canonical.digest(view)
    assert effect.digest == expected
    refute String.contains?(effect.digest, "term")
  end

  test "map key ordering cannot change effect identity" do
    a = PreparedEffect.new("p", :cap, %{"b" => 2, "a" => 1}, %{y: 2, x: 1})
    b = PreparedEffect.new("p", :cap, %{"a" => 1, "b" => 2}, %{x: 1, y: 2})
    assert a.digest == b.digest
  end

  test "non portable values are refused by build/4" do
    assert {:error, :canonical_type_forbidden} =
             PreparedEffect.build("p", :cap, "s", {:tuple, :not, :json})
  end
end

# ------------------------------------------------------------------------------
# Section 19: test/ash_a2a/c2/remote_endpoints_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.RemoteEndpointsTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{ActuatorClient, AuthorityClient, AuthorityRequest, Certificate, PreparedEffect}

  test "remote authority refuses before network when endpoint is absent" do
    effect = PreparedEffect.new("p", :cap, "s", %{})

    request =
      AuthorityRequest.new(effect, %{
        policy_epoch: 1,
        revocation_epoch: 1,
        generation: 1,
        audience: "a"
      })

    assert {:error, {:missing_c2_endpoint, :authority_endpoint}} =
             AuthorityClient.authorize(AuthorityClient.Remote, request, %{})
  end

  test "remote actuator refuses before network when endpoint is absent" do
    effect = PreparedEffect.new("p", :cap, "s", %{})

    cert = %Certificate{
      version: 1,
      effect_digest: effect.digest,
      principal: "p",
      policy_epoch: 1,
      revocation_epoch: 1,
      generation: 1,
      nonce: "n",
      not_before_ms: 0,
      expires_at_ms: 100,
      audience: "a",
      threshold: 1,
      signatures: []
    }

    assert {:error, {:missing_c2_endpoint, :actuator_endpoint}} =
             ActuatorClient.execute(ActuatorClient.Remote, effect, cert, %{})
  end
end

# ------------------------------------------------------------------------------
# Section 20: test/ash_a2a/c2/wire_contract_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.WireContractTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.{AuthorityRequest, PreparedEffect, Wire}

  test "authority wire carries the exact PreparedEffect digest and audience" do
    effect = PreparedEffect.new("principal:alice", :payments, %{"id" => 42}, %{"amount" => 100})

    request =
      AuthorityRequest.new(effect, %{
        policy_epoch: 4,
        revocation_epoch: 5,
        generation: 6,
        audience: "actuator:payments"
      })

    assert {:ok, wire} = Wire.authority_request(request)
    assert wire["effect_digest"] == effect.digest
    assert wire["effect"]["principal"] == "principal:alice"
    assert wire["effect"]["capability"] == "payments"
    assert wire["audience"] == "actuator:payments"
  end
end

# ------------------------------------------------------------------------------
# Section 21: test/ash_a2a/c2_compromise/c2_compromise_court_test.exs
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Section 22: test/ash_a2a/c2_compromise/catalog_integrity_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2Compromise.CatalogIntegrityTest do
  @moduledoc """
  Structural court over the harness itself, no processes started: the attack catalog covers
  every RFC-SA2A-006 s26 item that is meaningful against the real actuator/authority, every
  fence check is reached and (except the declared-redundant check 10) has an attack that
  must fail when the check is removed, and the mutation hooks of the actuator host script
  still match the actuator's sources exactly once (a refactor of fence.ex/store.ex must not
  silently turn mutants or fault points into no-ops).
  """
  use ExUnit.Case, async: true
  alias C2Harness.{Attack, Court}

  @root Path.expand("../../..", __DIR__)
  defp catalog, do: Court.catalog()
  defp everything, do: Court.catalog() ++ C2Harness.Entrypoint.attacks()

  test "attack ids are unique and every attack carries an RFC s26 mapping and a CAPEC/ATT&CK id" do
    ids = Enum.map(everything(), & &1.id)
    assert ids == Enum.uniq(ids)
    assert length(catalog()) >= 30

    for %Attack{} = a <- everything() do
      assert a.s26 != [], "#{a.id} names no s26 item"
      assert a.mapping.attck != [], "#{a.id} has no ATT&CK id"
      assert a.mapping.capec != [], "#{a.id} has no CAPEC id"
      assert a.mapping.atlas != [], "#{a.id} has no ATLAS id"
      assert Enum.all?(a.mapping.attck, &String.starts_with?(&1, "T")), "#{a.id} bad ATT&CK id"

      assert Enum.all?(a.mapping.capec, &String.starts_with?(&1, "CAPEC-")),
             "#{a.id} bad CAPEC id"

      assert Enum.all?(a.mapping.atlas, &String.starts_with?(&1, "AML.T")), "#{a.id} bad ATLAS id"
    end
  end

  test "every attack that can observe a refusal declares what it must observe (anti-vacuity)" do
    for %Attack{} = a <- catalog(), a.id not in ["C2C-F04"] do
      assert a.expect != [] or a.expect_any != [], "#{a.id} declares no expected observation"
    end
  end

  test "every fence check 1..16 is reached by at least one attack" do
    reached = catalog() |> Enum.flat_map(& &1.checks) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(1..16), reached)
  end

  test "every fence check except the declared-redundant check 10 has a killer attack" do
    killers = catalog() |> Enum.flat_map(& &1.killers_for) |> MapSet.new()
    assert MapSet.difference(MapSet.new(1..16), killers) == MapSet.new([10])
  end

  test "the s26 list is covered: each required item is named by at least one attack" do
    named = catalog() |> Enum.flat_map(& &1.s26) |> MapSet.new()

    required = [
      "forged capability",
      "forged PreparedEffect",
      "forged internal receipt",
      "fake standing",
      "mutated exact subject",
      "mutated canonical input",
      "fresh request id for an existing effect instance",
      "replay of a valid certificate",
      "expired certificate",
      "stale policy epoch",
      "revoked authority",
      "insufficient quorum",
      "single compromised signer below quorum",
      "duplicated DO",
      "worker crash before DO",
      "crash during uncertain DO",
      "restart after unknown outcome",
      "resource-budget amplification",
      "policy-option removal",
      "alternate adapter path",
      "path substitution",
      "arbitrary URL substitution",
      "command injection",
      "arbitrary deserialization payload"
    ]

    assert required -- MapSet.to_list(named) == []
  end

  test "the actuator host script's patch needles occur exactly once in the actuator sources" do
    fence = File.read!(Path.join(@root, "actuator/lib/actuator/fence.ex"))
    store = File.read!(Path.join(@root, "actuator/lib/actuator/store.ex"))

    for {src, needle} <- [
          {fence, "skip = Keyword.get(opts, :skip, [])"},
          {store, ":erlang.halt(137, flush: false)"},
          {store, "@fault Application.compile_env(:actuator, :fault_hook, false)"}
        ] do
      assert length(String.split(src, needle)) == 2, "needle #{inspect(needle)} is not unique"
    end
  end

  test "the fence still has exactly the 16 numbered checks the mutation court knows" do
    fence = File.read!(Path.join(@root, "actuator/lib/actuator/fence.ex"))

    nums =
      Regex.scan(~r/def check_(\d\d)_/, fence)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.uniq()
      |> Enum.sort()

    assert nums == Enum.to_list(1..16)
  end
end

# ------------------------------------------------------------------------------
# Section 23: test/ash_a2a/c2_compromise/oracle_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2Compromise.OracleTest do
  @moduledoc """
  The court's oracle, tested with NO processes: the pass rule of `C2Harness.Oracle` against
  ledgers and journals built here with an independent chain builder (`:crypto` + `Jcs`).
  Each test states a ledger/journal shape and asserts the verdict a correct oracle must
  return; reverting a guard in `Oracle.verdict/4` makes the matching test fail (the
  revert-mutation for each guard is recorded in docs/reference/c2-compromise-court.md).
  """
  use ExUnit.Case, async: true
  alias C2Harness.Oracle

  @zero String.duplicate("0", 64)
  @d1 "sha256:" <> String.duplicate("a", 64)
  @d2 "sha256:" <> String.duplicate("b", 64)

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # ledger entry chain, derived here (not by Actuator.Ledger)
  defp ledger(digests) do
    {entries, _} =
      digests
      |> Enum.with_index()
      |> Enum.map_reduce(@zero, fn {d, i}, prev ->
        body = %{
          "seq" => i,
          "prev" => prev,
          "effect_instance_id" => "ei:t-#{i}",
          "effect_digest" => d,
          "entry" => "e#{i}"
        }

        h = sha(prev <> Jcs.encode(body))
        {Map.put(body, "hash", h), h}
      end)

    entries
  end

  defp issuance(digests),
    do: for(d <- digests, do: %{"effect_digest" => d, "generation" => 1, "intended" => true})

  describe "verdict/4 (actuator ledger)" do
    test "zero new entries passes, even with nothing authorized" do
      assert {:pass, []} = Oracle.verdict(ledger([@d1]), ledger([@d1]), [], issuance([@d1]))
      assert {:pass, []} = Oracle.verdict([], [], [], [])
    end

    test "one new entry whose digest is authorized and journaled passes" do
      assert {:pass, [%{"effect_digest" => @d1}]} =
               Oracle.verdict([], ledger([@d1]), [@d1], issuance([@d1]))
    end

    test "a new entry the attack does not authorize is an unauthorized consequence" do
      assert {:fail, [{:unauthorized_entry, 0, @d2, :not_authorized_for_attack}], _} =
               Oracle.verdict([], ledger([@d2]), [@d1], issuance([@d1, @d2]))
    end

    test "authorized by the attack but absent from the issuance journal is unauthorized" do
      assert {:fail, reasons, _} = Oracle.verdict([], ledger([@d1]), [@d1], [])
      assert {:unauthorized_entry, 0, @d1, :not_in_issuance_journal} in reasons
    end

    test "a duplicated DO fails: one issuance buys at most one ledger entry" do
      assert {:fail, reasons, diff} =
               Oracle.verdict(ledger([@d1]), ledger([@d1, @d1]), [@d1], issuance([@d1]))

      assert {:duplicate_do, @d1, 2, 1} in reasons
      assert length(diff) == 1
    end

    test "two issuances of one digest buy two entries (the budget is the journal, not one)" do
      assert {:pass, _} = Oracle.verdict([], ledger([@d1, @d1]), [@d1], issuance([@d1, @d1]))
    end

    test "a violation by an EARLIER attack does not fail a later attack that touched other digests" do
      earlier_bad = ledger([@d1, @d1])
      later = earlier_bad ++ tail(earlier_bad, @d2)

      assert {:pass, [%{"effect_digest" => @d2}]} =
               Oracle.verdict(earlier_bad, later, [@d2], issuance([@d1, @d2]))
    end

    test "a tampered ledger entry breaks the chain" do
      good = ledger([@d1, @d2])
      tampered = List.update_at(good, 0, &Map.put(&1, "entry", "forged"))
      assert {:fail, reasons, _} = Oracle.verdict([], tampered, [], [])
      assert Enum.any?(reasons, &match?({:ledger_chain_broken, {:broken_chain, 0, :hash}}, &1))
    end

    test "a ledger whose earlier part was rewritten is not an extension of the snapshot" do
      before = ledger([@d1])
      rewritten = ledger([@d2, @d1])

      assert {:fail, reasons, _} =
               Oracle.verdict(before, rewritten, [@d1, @d2], issuance([@d1, @d2]))

      assert :ledger_rewritten in reasons
    end

    test "a deleted entry (shorter ledger) is a rewrite, never a pass" do
      assert {:fail, reasons, []} =
               Oracle.verdict(ledger([@d1, @d2]), ledger([@d1]), [], issuance([@d1, @d2]))

      assert :ledger_rewritten in reasons
    end
  end

  describe "verify_ledger/1 and verify_journal/1" do
    test "accept a valid chain, refuse a seq gap and a wrong prev" do
      good = ledger([@d1, @d2])
      assert :ok = Oracle.verify_ledger(good)

      assert {:error, {:broken_chain, 1, :seq}} =
               Oracle.verify_ledger([hd(good), Map.put(Enum.at(good, 1), "seq", 5)])

      assert {:error, {:broken_chain, 1, :prev}} =
               Oracle.verify_ledger([hd(good), Map.put(Enum.at(good, 1), "prev", @zero)])
    end

    test "journal chain uses the AuthorityService link form and refuses tampering" do
      lines =
        journal_lines([
          %{"effect_digest" => @d1, "generation" => 1},
          %{"effect_digest" => @d2, "generation" => 1}
        ])

      assert :ok = Oracle.verify_journal(lines)
      tampered = List.update_at(lines, 0, &put_in(&1, ["body", "generation"], 2))
      assert {:error, {:broken_chain, 1, :hash}} = Oracle.verify_journal(tampered)
    end

    test "files: a torn (unterminated) last line is a write in flight, not an entry" do
      dir = Path.join(System.tmp_dir!(), "c2-oracle-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      [e0, e1] = ledger([@d1, @d2])

      File.write!(
        Path.join(dir, "effect_ledger.jsonl"),
        Jason.encode!(e0) <> "\n" <> String.slice(Jason.encode!(e1), 0, 40)
      )

      assert {:ok, [_]} = Oracle.ledger(dir)

      File.write!(
        Path.join(dir, "effect_ledger.jsonl"),
        Jason.encode!(e0) <> "\n" <> Jason.encode!(e1) <> "\n"
      )

      assert {:ok, [_, _]} = Oracle.ledger(dir)
      File.write!(Path.join(dir, "effect_ledger.jsonl"), "not json\n")
      assert {:error, _, _} = Oracle.ledger(dir)
      File.rm_rf!(dir)
    end
  end

  describe "authority_verdict/3 (real AuthorityService journal)" do
    test "new issuances must be authorized pairs; no pair twice" do
      b1 = %{"effect_digest" => @d1, "generation" => 9}
      assert {:pass, [^b1]} = Oracle.authority_verdict([], [b1], [{@d1, 9}])

      assert {:fail, [{:unauthorized_issuance, {@d1, 9}}], _} =
               Oracle.authority_verdict([], [b1], [])

      assert {:fail, reasons, _} = Oracle.authority_verdict([b1], [b1, b1], [{@d1, 9}])
      assert {:duplicate_issuance, {@d1, 9}, 2} in reasons
    end

    test "a different generation of the same digest is a distinct (and unauthorized) issuance" do
      b = %{"effect_digest" => @d1, "generation" => 10}

      assert {:fail, [{:unauthorized_issuance, {@d1, 10}}], _} =
               Oracle.authority_verdict([], [b], [{@d1, 9}])
    end
  end

  defp tail(before, d) do
    prev = List.last(before)

    body = %{
      "seq" => length(before),
      "prev" => prev["hash"],
      "effect_instance_id" => "ei:x",
      "effect_digest" => d,
      "entry" => "x"
    }

    [Map.put(body, "hash", sha(prev["hash"] <> Jcs.encode(body)))]
  end

  defp journal_lines(bodies) do
    {lines, _} =
      bodies
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {body, i}, prev ->
        h = sha(prev <> Jcs.encode(%{"seq" => i, "body" => body}))
        {%{"seq" => i, "prev" => prev, "body" => body, "hash" => h}, h}
      end)

    lines
  end

  describe "Report.jsonable/1" do
    test "turns tuple/nil/atom map keys, tuples, atoms and structs into encodable JSON" do
      term = %{
        {false, true} => 2,
        nil => 1,
        :a => {:x, [1, :y]},
        3 => %C2Harness.ControlPlane{tls_port: 5}
      }

      json = term |> C2Harness.Report.jsonable() |> Jason.encode!() |> Jason.decode!()
      assert json["{false, true}"] == 2
      assert json["nil"] == 1
      assert json["a"] == ["x", [1, "y"]]
      assert json["3"]["tls_port"] == 5
    end
  end
end

# ------------------------------------------------------------------------------
# Section 24: test/ash_a2a/c3/signer_set_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C3.SignerSetTest do
  # DB-free: real Ed25519 keys and signatures (:crypto), real Sa2aCrypto registry and
  # verifier; no Repo, no Oban.
  use ExUnit.Case, async: true
  alias AshA2A.C3.SignerSet
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, SignedMessage}
  alias Sa2aCrypto.Registry.Static

  @aud "actuator:c3-test"
  @now 1_800_000_000

  defp key(custodian, tier \\ :i2) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    kid = KeyRef.kid!("EdDSA", pub)

    %{
      priv: priv,
      kid: kid,
      record: %KeyRecord{
        kid: kid,
        alg: "EdDSA",
        public_key: pub,
        custodian_id: custodian,
        custody_tier: tier,
        state: :active,
        revocation_epoch: 0
      }
    }
  end

  defp approve(k, sign_with \\ nil) do
    fields = %{
      "v" => 1,
      "alg" => "EdDSA",
      "kid" => k.kid,
      "effect_digest" => "sha256:" <> String.duplicate("cd", 32),
      "principal" => "agent:c3",
      "policy_epoch" => 1,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "n-" <> k.kid,
      "not_before" => @now - 60,
      "expires" => @now + 300,
      "audience" => @aud
    }

    {:ok, bytes} = SignedMessage.build(fields)
    sig = :crypto.sign(:eddsa, :none, bytes, [sign_with || k.priv, :ed25519])

    env = %Envelope{
      v: 1,
      alg: "EdDSA",
      kid: k.kid,
      profile: :classical,
      signed_bytes_digest: SignedMessage.digest(bytes),
      signature: sig,
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: @aud
    }

    {env, bytes}
  end

  defp policy(k), do: %{k: k, audience: @aud, now: @now}

  test "two kids of one custodian are one signer; two custodians are a quorum" do
    [a1, a2, b] = ks = [key("A"), key("A"), key("B")]
    view = Static.view(Enum.map(ks, & &1.record))

    assert {:error, :quorum_not_met} =
             SignerSet.evaluate([approve(a1), approve(a2)], nil, view, policy(2))

    assert {:ok, %{custodians: ["A", "B"], tier: :i2}} =
             SignerSet.evaluate([approve(a1), approve(a2), approve(b)], nil, view, policy(2))
  end

  test "a signer label without a verifiable signature counts zero" do
    [a, b] = ks = [key("A"), key("B")]
    attacker = key("evil")
    view = Static.view(Enum.map(ks, & &1.record))
    forged = approve(b, attacker.priv)

    assert {:error, :quorum_not_met} =
             SignerSet.evaluate([approve(a), forged], nil, view, policy(2))

    # the legacy shape (`%{signer: label}`) is not evidence of anything
    assert {:error, :quorum_not_met} =
             SignerSet.evaluate(
               [approve(a), {%{signer: "B", custodian_id: "B"}, "x"}],
               nil,
               view,
               policy(2)
             )
  end

  test "quorum/2 over standings counts distinct custodians of valid standings only" do
    valid = fn kid, c, t -> {:valid, %{kid: kid, custodian_id: c, tier: t, epoch: 0}} end

    assert {:error, :quorum_not_met} =
             SignerSet.quorum([valid.("k1", "c1", :i2), valid.("k2", "c1", :i2)], 2)

    assert {:error, :quorum_not_met} =
             SignerSet.quorum([valid.("k1", "c1", :i2), {:invalid, :bad_signature}], 2)

    assert {:error, :quorum_not_met} = SignerSet.quorum([], 2)

    assert {:ok, %{custodians: ["c1", "c2"], tier: :i1}} =
             SignerSet.quorum([valid.("k1", "c1", :i2), valid.("k2", "c2", :i1)], 2)
  end

  test "the label-counting threshold?/2 is gone" do
    Code.ensure_loaded!(SignerSet)
    refute function_exported?(SignerSet, :threshold?, 2)
  end
end
