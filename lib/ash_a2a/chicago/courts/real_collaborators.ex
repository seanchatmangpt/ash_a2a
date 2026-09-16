defmodule AshA2A.Chicago.Courts.RealCollaborators do
  @moduledoc """
  RFC-SA2A-002 gate 3 -- Real Collaborators / Zero Mocks (§9, §10, §34).

  Attacks `AshA2A.Chicago.Collaborators` -- the boundary that decides whether
  the running configuration's load-bearing collaborators are real -- by
  changing the *environment* around real components (application
  configuration, a real store module that lies about durability, a real broker
  that grants everyone, a real wasm file that is not GraphLaw, real source
  trees that call mocking libraries) and checking that each substitution is
  detected. Positive controls prove discrimination: the repository's real
  configuration is admitted, a really durable store (`AshA2A.ReceiptStore.Ekv`)
  is proven durable across a real restart, and source that only *mentions*
  mocking libraries passes the AST scan.

  Configuration changes are applied with `Application.put_env/3` for the
  duration of one stimulus and restored afterwards; courts run one at a time
  (`AshA2A.Chicago.Runner`), so no other stimulus observes them.

  Attempt evidence comes from telemetry emitted by the deciding boundaries
  (`AshA2A.Chicago.Collaborators`, `AshA2A.Authority.Grant.authorize/3`,
  `AshA2A.GraphLaw.Wasm.batch/2`), never from this court.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Collaborators, Context, Falsifier, Result}
  alias AshA2A.Chicago.Courts.AuthorityHarness
  alias AshA2A.Chicago.Fixtures.RealCollaborators, as: Fixtures
  alias AshA2A.Chicago.Ocel.Mapping

  @court "CHI-REAL"

  @inventoried "chicago.collaborators.inventoried"
  @violation "chicago.collaborators.violation"
  @scan "chicago.collaborators.mock_scan"
  @probe "chicago.collaborators.durability_probe"
  # The grant decision is the ONE `[:ash_a2a, :authority, :decision]` event
  # `AshA2A.Authority.Grant.authorize/3` emits; its OCEL mapping is the shared
  # `AshA2A.Chicago.Courts.AuthorityHarness` one, so a run with this court and
  # the SA2A-AUTH courts admits it once (one emission, one OCEL event).
  @grant "authority.decision"
  @grant_event [:ash_a2a, :authority, :decision]
  @batch "graph_law.wasm.batch"

  @seeded_mock_test ~S"""
  defmodule Seeded.MockedClockTest do
    use ExUnit.Case
    import Mox

    test "clock is mocked" do
      Mox.expect(Seeded.ClockMock, :now, fn -> 0 end)
      :meck.new(Seeded.Clock, [:passthrough])

      with_mock Seeded.Clock, now: fn -> 0 end do
        assert Seeded.Clock.now() == 0
      end

      patch(Seeded.Clock, :now, 0)
    end
  end
  """

  @seeded_mock_lib ~S"""
  defmodule Seeded.ClockMocks do
    Mox.defmock(Seeded.ClockMock, for: Seeded.Clock)
  end
  """

  # Exact file:line of every real mocking call in the seeded tree above.
  @seeded_mock_hits [
    {"lib/seeded_clock_mocks.ex", 2},
    {"test/seeded_mocked_clock_test.exs", 3},
    {"test/seeded_mocked_clock_test.exs", 6},
    {"test/seeded_mocked_clock_test.exs", 7},
    {"test/seeded_mocked_clock_test.exs", 9},
    {"test/seeded_mocked_clock_test.exs", 13}
  ]

  @seeded_text_only_lib ~S'''
  defmodule Seeded.TextOnly do
    @moduledoc """
    This module never calls Mox.expect/3, :meck.new/2, with_mock/3 or
    patch(Clock, :now, 0) -- it only talks about them.
    """

    # Mox.expect(Seeded.ClockMock, :now, fn -> 0 end)  <- a comment, not a call
    # import Mox

    @mocking_libraries [:meck, :mox, Mox, Mock]

    def libraries, do: @mocking_libraries
    def example, do: "Mox.stub(Clock, :now, 1); :meck.new(Clock); with_mock Clock, [] do end"
    def http(conn), do: patch(conn, "/items")
    def dispatch(message), do: {:dispatched, message}
    def sigil, do: ~S(import Mox)
  end
  '''

  @seeded_text_only_test ~S"""
  defmodule Seeded.RouterTest do
    use ExUnit.Case

    test "patch is an HTTP verb here" do
      conn = patch(build_conn(), "/items/1", %{"label" => "x"})
      assert conn
    end
  end
  """

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Real collaborators / zero mocks"
  @impl true
  def gate, do: 3
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§9", "§10", "§34", "§100"]

  @impl true
  def refusal_codes, do: Collaborators.__sa2a_refusal_codes__()

  @doc false
  def seeded_mock_hits, do: @seeded_mock_hits

  @impl true
  def falsifiers do
    [
      Falsifier.new!(
        id: "CHI-REAL-001",
        court_id: @court,
        kind: :negative,
        invariant:
          "A legacy :transport_verified_grants_capability authority policy is not a real authority boundary and must not be admitted",
        stimulus:
          "config :ash_a2a, authority_policy: :transport_verified_grants_capability; Collaborators.inventory(roles: [:authority_broker])",
        boundary:
          "AshA2A.Chicago.Collaborators authority probe via AshA2A.Authority.Grant.authorize/3",
        forbidden_outcome:
          "inventory reports authority fail-closed, or no :authority_not_real_boundary violation",
        attempt_evidence:
          "authority.decision under the legacy policy granted a fresh ungranted nonce principal; inventory emitted",
        survival_evidence:
          "inventoried authority_fail_closed=true, or no violation code=authority_not_real_boundary",
        guard: "Collaborators authority_broker role: fail_closed_proven? from the nonce probe",
        failure_class: :authority_failure,
        rfc_sections: ["§10", "§34", "RFC-SA2A-001 S29"],
        attempt_predicate:
          {:all,
           [
             {:observed, @grant,
              %{"policy" => "transport_verified_grants_capability", "outcome" => "granted"}},
             {:observed, @inventoried}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"authority_fail_closed" => "true"}},
             {:not_observed, @violation, %{"code" => "authority_not_real_boundary"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-002",
        court_id: @court,
        kind: :negative,
        invariant:
          "A broker that answers granted?/3 true without a grant (fake broker response) is not a real authority boundary",
        stimulus:
          "config :ash_a2a, authority_broker: Fixtures.RealCollaborators.AlwaysGrantBroker under :broker policy; inventory(roles: [:authority_broker])",
        boundary:
          "AshA2A.Chicago.Collaborators authority probe via AshA2A.Authority.Grant.authorize/3",
        forbidden_outcome:
          "inventory reports authority fail-closed, or no :authority_not_real_boundary violation",
        attempt_evidence:
          "authority.decision under :broker policy with the always-grant broker granted the nonce principal",
        survival_evidence:
          "inventoried authority_fail_closed=true, or no violation code=authority_not_real_boundary",
        guard:
          "Collaborators authority_broker role: behavioural nonce probe, not a policy-name check",
        failure_class: :authority_failure,
        rfc_sections: ["§10", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @grant,
              %{
                "policy" => "broker",
                "broker" => inspect(Fixtures.AlwaysGrantBroker),
                "outcome" => "granted"
              }},
             {:observed, @inventoried}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"authority_fail_closed" => "true"}},
             {:not_observed, @violation, %{"code" => "authority_not_real_boundary"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-003",
        court_id: @court,
        kind: :negative,
        invariant: "A DO claim is refused when the receipt store is not durable",
        stimulus:
          "config :ash_a2a, receipt_store: AshA2A.ReceiptStore.Memory; inventory(claim: :do, roles: [:receipt_store, :replay_engine])",
        boundary: "AshA2A.Chicago.Collaborators receipt_store role + DurabilityProbe",
        forbidden_outcome: "inventory admitted, or no :receipt_store_not_durable violation",
        attempt_evidence:
          "durability probe really restarted the Memory store instance; inventory emitted under claim=do",
        survival_evidence:
          "inventoried verdict=admitted, or no violation code=receipt_store_not_durable",
        guard: "Collaborators receipt_store violations: @durable_claims clause",
        failure_class: :receipt_failure,
        rfc_sections: ["§29", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @probe,
              %{
                "store" => "AshA2A.ReceiptStore.Memory",
                "stage" => "restart",
                "outcome" => "restarted"
              }},
             {:observed, @inventoried,
              %{"claim" => "do", "receipt_store" => "AshA2A.ReceiptStore.Memory"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"verdict" => "admitted"}},
             {:not_observed, @violation, %{"code" => "receipt_store_not_durable"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-004",
        court_id: @court,
        kind: :negative,
        invariant:
          "Durability is proven, not declared: a ReceiptStore declaring durable?() true that loses writes across a real restart is detected",
        stimulus:
          "config :ash_a2a, receipt_store: Fixtures.RealCollaborators.LossyDurableStore; inventory(roles: [:receipt_store, :replay_engine])",
        boundary: "AshA2A.Chicago.Collaborators.DurabilityProbe (write -> real restart -> read)",
        forbidden_outcome:
          "inventory reports the store proven durable, or no :receipt_store_durability_unproven violation",
        attempt_evidence:
          "probe committed a nonce receipt, restarted the store process (new pid), and read it back",
        survival_evidence:
          "inventoried receipt_store_proven_durable=true, or no violation code=receipt_store_durability_unproven",
        guard: "DurabilityProbe.verdict/1 read == :found requirement",
        failure_class: :receipt_failure,
        rfc_sections: ["§10", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @probe, %{"stage" => "write", "outcome" => "committed"}},
             {:observed, @probe, %{"stage" => "restart", "outcome" => "restarted"}},
             {:observed, @probe, %{"stage" => "read"}},
             {:observed, @inventoried, %{"receipt_store_declared_durable" => "true"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"receipt_store_proven_durable" => "true"}},
             {:not_observed, @violation, %{"code" => "receipt_store_durability_unproven"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-005",
        court_id: @court,
        kind: :negative,
        invariant:
          "The zero-mock AST scan fails on every real call into Mox/Mock/:meck/with_mock/patch, with file:line",
        stimulus:
          "Collaborators.mock_scan/1 over a real source tree seeding import Mox, Mox.expect/3, :meck.new/2, with_mock/3, patch/3, Mox.defmock/2",
        boundary: "AshA2A.Chicago.Collaborators.MockScan (Code.string_to_quoted AST walk)",
        forbidden_outcome:
          "scan clean, or any seeded call site not reported at its exact file:line",
        attempt_evidence: "chicago.collaborators.mock_scan emitted over the seeded tree",
        survival_evidence:
          "mock_scan outcome=clean, or a missing violation event for a seeded (file, line)",
        guard: "MockScan.collect/3 call-shape clauses",
        failure_class: :validator_failure,
        rfc_sections: ["§10", "§34"],
        attempt_predicate: {:observed, @scan},
        outcome_predicate:
          {:any,
           [
             {:observed, @scan, %{"outcome" => "clean"}}
             | Enum.map(@seeded_mock_hits, fn {file, line} ->
                 {:not_observed, @violation,
                  %{"code" => "mock_collaborator_detected", "file" => file, "line" => line}}
               end)
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-006",
        court_id: @court,
        kind: :negative,
        invariant:
          "The semantic engine pointed by configuration at a non-GraphLaw wasm is detected as substituted",
        stimulus:
          "config :ash_a2a, graphlaw_wasm_path: <real file holding an empty wasm module>; inventory(roles: [:semantic_engine])",
        boundary:
          "AshA2A.Chicago.Collaborators semantic_engine role (manifest digest + real execution + independent reference)",
        forbidden_outcome:
          "inventory reports the semantic engine real, or no :semantic_engine_substituted violation",
        attempt_evidence:
          "graph_law.wasm.batch: the real host was handed the stub and failed; semantic_engine inventory emitted",
        survival_evidence:
          "inventoried semantic_engine_real=true, or no violation code=semantic_engine_substituted",
        guard: "Collaborators semantic_engine real?: digest_bound? and agrees_with_reference?",
        failure_class: :identity_failure,
        rfc_sections: ["§9", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @batch, %{"outcome" => "error"}},
             {:observed, @inventoried, %{"roles" => "semantic_engine"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"semantic_engine_real" => "true"}},
             {:not_observed, @violation, %{"code" => "semantic_engine_substituted"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-007",
        court_id: @court,
        kind: :negative,
        invariant:
          "An AshA2A.Semantic.GraphLaw port impl substituted by configuration with a non-executing stub is detected",
        stimulus:
          "config :ash_a2a, graph_law: Fixtures.RealCollaborators.StubGraphLawPort; inventory(roles: [:semantic_engine])",
        boundary:
          "AshA2A.Chicago.Collaborators semantic port differential probe (fresh nonce graph vs manifest-bound reference)",
        forbidden_outcome:
          "inventory reports the port real, or no :semantic_port_substituted violation",
        attempt_evidence:
          "inventory emitted naming the stub port; the real host executed the reference (graph_law.wasm.batch ok)",
        survival_evidence:
          "inventoried semantic_port_real=true, or no violation code=semantic_port_substituted",
        guard: "Collaborators semantic_port real?: agrees_with_reference?",
        failure_class: :identity_failure,
        rfc_sections: ["§9", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @batch, %{"outcome" => "ok"}},
             {:observed, @inventoried, %{"semantic_port" => inspect(Fixtures.StubGraphLawPort)}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"semantic_port_real" => "true"}},
             {:not_observed, @violation, %{"code" => "semantic_port_substituted"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-011",
        court_id: @court,
        kind: :negative,
        invariant:
          "Semantic engine identity is exact: an artifact that behaves like GraphLaw but whose bytes differ from the manifest-bound artifact is not admitted",
        stimulus:
          "config :ash_a2a, graphlaw_wasm_path: <the real GraphLaw wasm with one appended custom section>; inventory(roles: [:semantic_engine])",
        boundary: "AshA2A.Chicago.Collaborators semantic_engine role (manifest sha256 binding)",
        forbidden_outcome:
          "inventory reports the semantic engine real, or no :semantic_engine_substituted violation",
        attempt_evidence:
          "graph_law.wasm.batch ok: the real host executed the tampered artifact; semantic_engine inventory emitted",
        survival_evidence:
          "inventoried semantic_engine_real=true, or no violation code=semantic_engine_substituted",
        guard:
          "Collaborators semantic_engine digest_bound?: wasm sha256 == manifest artifact sha256",
        failure_class: :identity_failure,
        rfc_sections: ["§5", "§9", "§34"],
        attempt_predicate:
          {:all,
           [
             {:observed, @batch, %{"outcome" => "ok"}},
             {:observed, @inventoried, %{"roles" => "semantic_engine"}}
           ]},
        outcome_predicate:
          {:any,
           [
             {:observed, @inventoried, %{"semantic_engine_real" => "true"}},
             {:not_observed, @violation, %{"code" => "semantic_engine_substituted"}}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-008",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "The repository's real configuration identifies all nine §34 roles, proves them real, and its lib/ + test/ are mock-free",
        stimulus:
          "Collaborators.inventory(claim: :core, observer: run observer) over the unmodified configuration and File.cwd!() lib/ + test/",
        boundary: "AshA2A.Chicago.Collaborators (full inventory + zero-mock scan)",
        attempt_evidence:
          "authority probe refused under :broker; real GraphLaw host executed; store really restarted; scan ran over lib,test",
        survival_evidence:
          "inventoried verdict=admitted scope=full roles_identified=9 with authority fail-closed, engine and port real, scan clean; no violation",
        attempt_predicate:
          {:all,
           [
             {:observed, @grant, %{"policy" => "broker", "outcome" => "refused"}},
             {:observed, @batch, %{"outcome" => "ok"}},
             {:observed, @probe, %{"stage" => "restart", "outcome" => "restarted"}},
             {:observed, @scan, %{"dirs" => "lib,test"}}
           ]},
        outcome_predicate:
          {:all,
           [
             {:observed, @inventoried,
              %{
                "verdict" => "admitted",
                "scope" => "full",
                "roles_identified" => 9,
                "authority_fail_closed" => "true",
                "semantic_engine_real" => "true",
                "semantic_port_real" => "true",
                "mock_scan" => "clean",
                "process_observer_live" => "true"
              }},
             {:observed, @scan, %{"outcome" => "clean"}},
             {:not_observed, @violation}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-009",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A really durable store (AshA2A.ReceiptStore.Ekv) is proven durable across a real restart and admitted under a DO claim",
        stimulus:
          "config :ash_a2a, receipt_store: AshA2A.ReceiptStore.Ekv; inventory(claim: :do, roles: [:receipt_store, :replay_engine])",
        boundary: "AshA2A.Chicago.Collaborators.DurabilityProbe over a real EKV instance",
        attempt_evidence: "probe committed, restarted the EKV instance (new pid), read",
        survival_evidence:
          "read found the same receipt identity, re-claim answered replay, inventory admitted under claim=do",
        attempt_predicate:
          {:all,
           [
             {:observed, @probe,
              %{
                "store" => "AshA2A.ReceiptStore.Ekv",
                "stage" => "write",
                "outcome" => "committed"
              }},
             {:observed, @probe, %{"stage" => "restart", "outcome" => "restarted"}}
           ]},
        outcome_predicate:
          {:all,
           [
             {:observed, @probe, %{"stage" => "read", "outcome" => "found"}},
             {:observed, @probe, %{"stage" => "replay", "outcome" => "replay"}},
             {:observed, @inventoried,
              %{
                "claim" => "do",
                "verdict" => "admitted",
                "receipt_store_proven_durable" => "true",
                "replay_after_restart" => "true"
              }},
             {:not_observed, @violation}
           ]}
      ),
      Falsifier.new!(
        id: "CHI-REAL-010",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "The zero-mock scan discriminates: comments, docs, strings, sigils, atoms and Phoenix-style patch/3 that only mention mocking libraries pass",
        stimulus:
          "Collaborators.mock_scan/1 over a real source tree that names but never calls them",
        boundary: "AshA2A.Chicago.Collaborators.MockScan",
        attempt_evidence: "chicago.collaborators.mock_scan emitted over the text-only tree",
        survival_evidence: "mock_scan outcome=clean and no violation event",
        attempt_predicate: {:observed, @scan},
        outcome_predicate:
          {:all, [{:observed, @scan, %{"outcome" => "clean"}}, {:not_observed, @violation}]}
      )
    ]
  end

  @impl true
  def run(%Context{} = ctx) do
    by_id = Map.new(falsifiers(), &{&1.id, &1})
    work_dir = Path.join(ctx.evidence_dir, "real_collaborators")

    [
      guarded(by_id["CHI-REAL-001"], fn f -> legacy_authority(ctx, f) end),
      guarded(by_id["CHI-REAL-002"], fn f -> always_grant_broker(ctx, f) end),
      guarded(by_id["CHI-REAL-003"], fn f -> memory_store_under_do(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-004"], fn f -> lossy_durable_store(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-005"], fn f -> seeded_mocks(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-006"], fn f -> stub_wasm_path(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-007"], fn f -> stub_port(ctx, f) end),
      guarded(by_id["CHI-REAL-011"], fn f -> tampered_graphlaw(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-008"], fn f -> real_configuration(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-009"], fn f -> ekv_store_under_do(ctx, f, work_dir) end),
      guarded(by_id["CHI-REAL-010"], fn f -> text_only_mentions(ctx, f, work_dir) end)
    ]
  end

  # --- falsifiers -------------------------------------------------------------

  defp legacy_authority(ctx, f) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([authority_policy: :transport_verified_grants_capability], fn ->
          Collaborators.inventory(claim: :core, roles: [:authority_broker], scan: false)
        end)
      end)

    authority_result(ctx, f, inv)
  end

  defp always_grant_broker(ctx, f) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env(
          [authority_policy: :broker, authority_broker: Fixtures.AlwaysGrantBroker],
          fn -> Collaborators.inventory(claim: :core, roles: [:authority_broker], scan: false) end
        )
      end)

    authority_result(ctx, f, inv)
  end

  defp authority_result(ctx, f, inv) do
    role = inv.roles.authority_broker

    Result.negative(f,
      attempt_observed?:
        role.ungranted_principal_obtained_authority? and Context.observed?(ctx, f, @grant) and
          Context.observed?(ctx, f, @inventoried),
      forbidden_outcome_observed?:
        role.fail_closed_proven? or
          not Collaborators.violation?(inv, :authority_not_real_boundary),
      evidence: evidence(inv, :authority_broker)
    )
  end

  defp memory_store_under_do(ctx, f, work_dir) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([receipt_store: AshA2A.ReceiptStore.Memory], fn ->
          Collaborators.inventory(
            claim: :do,
            roles: [:receipt_store, :replay_engine],
            scan: false,
            probe_dir: probe_dir(work_dir)
          )
        end)
      end)

    role = inv.roles.receipt_store

    Result.negative(f,
      attempt_observed?:
        role.module == AshA2A.ReceiptStore.Memory and role.durability.restarted? and
          Context.observed?(ctx, f, @probe),
      forbidden_outcome_observed?:
        inv.verdict == :admitted or not Collaborators.violation?(inv, :receipt_store_not_durable),
      evidence: evidence(inv, :receipt_store)
    )
  end

  defp lossy_durable_store(ctx, f, work_dir) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([receipt_store: Fixtures.LossyDurableStore], fn ->
          Collaborators.inventory(
            claim: :core,
            roles: [:receipt_store, :replay_engine],
            scan: false,
            probe_dir: probe_dir(work_dir)
          )
        end)
      end)

    role = inv.roles.receipt_store

    Result.negative(f,
      attempt_observed?:
        role.declared_durable? and role.durability.write == :committed and
          role.durability.restarted? and role.durability.read != :skipped and
          Context.observed?(ctx, f, @probe),
      forbidden_outcome_observed?:
        role.proven_durable? or
          not Collaborators.violation?(inv, :receipt_store_durability_unproven),
      evidence: evidence(inv, :receipt_store)
    )
  end

  defp seeded_mocks(ctx, f, work_dir) do
    root = Path.join(work_dir, "seeded_mock_tree")

    write_tree!(root, %{
      "lib/seeded_clock_mocks.ex" => @seeded_mock_lib,
      "test/seeded_mocked_clock_test.exs" => @seeded_mock_test
    })

    {scan, _violations} =
      Context.stimulus(ctx, f, fn ->
        Collaborators.mock_scan(root: root, dirs: ["lib", "test"])
      end)

    reported = MapSet.new(scan.violations, &{&1.file, &1.line})

    Result.negative(f,
      attempt_observed?: scan.files == 2 and Context.observed?(ctx, f, @scan),
      forbidden_outcome_observed?:
        scan.outcome == :clean or
          not Enum.all?(@seeded_mock_hits, &MapSet.member?(reported, &1)),
      evidence: %{"scan" => scan}
    )
  end

  defp stub_wasm_path(ctx, f, work_dir) do
    stub = Path.join([work_dir, "stub_engine", "praxis_graphlaw.wasm"])
    File.mkdir_p!(Path.dirname(stub))
    # A valid, empty WebAssembly module: real wasm bytes, not GraphLaw.
    File.write!(stub, <<0, ?a, ?s, ?m, 1, 0, 0, 0>>)

    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([graphlaw_wasm_path: stub], fn ->
          Collaborators.inventory(claim: :core, roles: [:semantic_engine], scan: false)
        end)
      end)

    role = inv.roles.semantic_engine

    Result.negative(f,
      attempt_observed?:
        role.wasm_path == stub and role.wasm_sha256 != nil and
          Context.observed?(ctx, f, @batch),
      forbidden_outcome_observed?:
        role.real? or not Collaborators.violation?(inv, :semantic_engine_substituted),
      evidence: evidence(inv, :semantic_engine)
    )
  end

  defp tampered_graphlaw(ctx, f, work_dir) do
    tampered = Path.join([work_dir, "tampered_engine", "praxis_graphlaw.wasm"])
    File.mkdir_p!(Path.dirname(tampered))
    # The real GraphLaw bytes plus one custom section (id 0, name "chicago",
    # payload "tamper"): still a valid module that executes identically.
    File.write!(tampered, [
      File.read!(AshA2A.GraphLaw.wasm_path()),
      <<0, 14, 7, "chicago", "tamper">>
    ])

    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([graphlaw_wasm_path: tampered], fn ->
          Collaborators.inventory(claim: :core, roles: [:semantic_engine], scan: false)
        end)
      end)

    role = inv.roles.semantic_engine

    Result.negative(f,
      attempt_observed?:
        role.wasm_path == tampered and role.version == role.manifest_version and
          role.agrees_with_reference? and Context.observed?(ctx, f, @batch),
      forbidden_outcome_observed?:
        role.real? or not Collaborators.violation?(inv, :semantic_engine_substituted),
      evidence: evidence(inv, :semantic_engine)
    )
  end

  defp stub_port(ctx, f) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([graph_law: Fixtures.StubGraphLawPort], fn ->
          Collaborators.inventory(claim: :core, roles: [:semantic_engine], scan: false)
        end)
      end)

    role = inv.roles.semantic_engine

    Result.negative(f,
      attempt_observed?:
        role.port.module == Fixtures.StubGraphLawPort and role.reference.available? and
          Context.observed?(ctx, f, @inventoried),
      forbidden_outcome_observed?:
        role.port.real? or not Collaborators.violation?(inv, :semantic_port_substituted),
      evidence: evidence(inv, :semantic_engine)
    )
  end

  defp real_configuration(ctx, f, work_dir) do
    inv =
      Context.stimulus(ctx, f, fn ->
        Collaborators.inventory(
          claim: :core,
          observer: ctx.observer,
          root: File.cwd!(),
          probe_dir: probe_dir(work_dir)
        )
      end)

    Result.positive(f,
      attempt_observed?:
        inv.scope == :full and inv.mock_scan != nil and inv.mock_scan.files > 0 and
          Context.observed?(ctx, f, @grant) and Context.observed?(ctx, f, @batch),
      expected_outcome_observed?:
        inv.verdict == :admitted and
          Enum.all?(inv.roles, fn {_role, map} -> map.identified? end) and
          inv.roles.authority_broker.fail_closed_proven? and inv.roles.semantic_engine.real? and
          inv.roles.semantic_engine.port.real? and inv.mock_scan.outcome == :clean,
      evidence: %{
        "verdict" => inv.verdict,
        "violations" => inv.violations,
        "collaborators" =>
          Map.new(inv.roles, fn {role, map} -> {role, Map.get(map, :module)} end),
        "semantic_engine" => Map.delete(inv.roles.semantic_engine, :port),
        "receipt_store" => inv.roles.receipt_store,
        "mock_scan" => Map.take(inv.mock_scan, [:root, :dirs, :files, :outcome])
      }
    )
  end

  defp ekv_store_under_do(ctx, f, work_dir) do
    inv =
      Context.stimulus(ctx, f, fn ->
        with_env([receipt_store: AshA2A.ReceiptStore.Ekv], fn ->
          Collaborators.inventory(
            claim: :do,
            roles: [:receipt_store, :replay_engine],
            scan: false,
            probe_dir: probe_dir(work_dir)
          )
        end)
      end)

    role = inv.roles.receipt_store

    Result.positive(f,
      attempt_observed?:
        role.module == AshA2A.ReceiptStore.Ekv and role.durability.write == :committed and
          role.durability.restarted? and Context.observed?(ctx, f, @probe),
      expected_outcome_observed?:
        inv.verdict == :admitted and role.proven_durable? and
          inv.roles.replay_engine.replay_after_restart?,
      evidence: evidence(inv, :receipt_store)
    )
  end

  defp text_only_mentions(ctx, f, work_dir) do
    root = Path.join(work_dir, "seeded_text_only_tree")

    write_tree!(root, %{
      "lib/seeded_text_only.ex" => @seeded_text_only_lib,
      "test/seeded_router_test.exs" => @seeded_text_only_test
    })

    {scan, violations} =
      Context.stimulus(ctx, f, fn ->
        Collaborators.mock_scan(root: root, dirs: ["lib", "test"])
      end)

    Result.positive(f,
      attempt_observed?: scan.files == 2 and Context.observed?(ctx, f, @scan),
      expected_outcome_observed?: scan.outcome == :clean and violations == [],
      evidence: %{"scan" => scan}
    )
  end

  # --- OCEL mappings for the telemetry this court relies on -----------------

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :chicago, :collaborators, :inventoried],
        activity: @inventoried,
        source: __MODULE__,
        objects: fn _m, meta ->
          for {role, module} <- List.wrap(meta[:collaborators]), module != nil do
            {"collaborator", "#{role}:#{inspect(module)}", Atom.to_string(role)}
          end
        end,
        attributes: fn _m, meta -> attrs(Map.delete(meta, :collaborators)) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :chicago, :collaborators, :violation],
        activity: @violation,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"collaborator", meta[:module] && "#{meta[:role]}:#{inspect(meta[:module])}",
             "violating"},
            {"source_file", meta[:file], "violating_file"}
          ]
        end,
        attributes: fn _m, meta -> attrs(meta) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :chicago, :collaborators, :mock_scan],
        activity: @scan,
        source: __MODULE__,
        objects: fn _m, meta -> [{"source_tree", meta[:root], "scanned"}] end,
        attributes: fn m, meta -> attrs(Map.merge(meta, m)) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :chicago, :collaborators, :durability_probe],
        activity: @probe,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"receipt_store", meta[:store] && inspect(meta[:store]), "probed_store"},
            {"command", meta[:command_id], "probe_command"}
          ]
        end,
        attributes: fn _m, meta -> attrs(Map.take(meta, [:store, :stage, :outcome])) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :graph_law, :wasm, :batch],
        activity: @batch,
        source: __MODULE__,
        objects: fn _m, meta -> [{"wasm_artifact", meta[:wasm_path], "executed_artifact"}] end,
        attributes: fn m, meta ->
          attrs(Map.merge(Map.take(meta, [:outcome, :code, :wasm_path]), m))
        end
      )
    ] ++ Enum.filter(AuthorityHarness.mappings(), &(&1.event == @grant_event))
  end

  # Module atoms render as their Elixir name ("AshA2A.ReceiptStore.Memory"),
  # other atoms as plain strings ("broker").
  defp attrs(map) do
    Map.new(map, fn
      {k, v} when is_atom(v) and v not in [nil, true, false] ->
        string = Atom.to_string(v)
        {k, if(String.starts_with?(string, "Elixir."), do: inspect(v), else: string)}

      {k, v} ->
        {k, v}
    end)
  end

  # --- helpers ----------------------------------------------------------------

  defp guarded(%Falsifier{} = f, fun) do
    fun.(f)
  rescue
    exception ->
      Result.unknown(
        f,
        "stimulus raised: " <> Exception.format(:error, exception, __STACKTRACE__)
      )
  catch
    kind, reason ->
      Result.unknown(f, "stimulus #{kind}: #{inspect(reason, limit: 20)}")
  end

  defp with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {key, _} -> {key, Application.fetch_env(:ash_a2a, key)} end)
    Enum.each(pairs, fn {key, value} -> Application.put_env(:ash_a2a, key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ash_a2a, key, value)
        {key, :error} -> Application.delete_env(:ash_a2a, key)
      end)
    end
  end

  defp write_tree!(root, files) do
    File.rm_rf!(root)

    Enum.each(files, fn {rel, source} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end)
  end

  defp probe_dir(work_dir) do
    dir = Path.join(work_dir, "durability_probe")
    File.mkdir_p!(dir)
    dir
  end

  defp evidence(inv, role) do
    %{
      "claim" => inv.claim,
      "verdict" => inv.verdict,
      "violations" => inv.violations,
      Atom.to_string(role) => Map.get(inv.roles, role)
    }
  end
end
