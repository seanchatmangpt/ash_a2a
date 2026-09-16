defmodule AshA2A.AuthorityKillerNegativeTest do
  @moduledoc """
  THE KILLER NEGATIVE FIXTURE (RFC-SA2A-001 S28, S29, S30, S60).

  One semantically valid operation walks the whole manufacturing chain --

      ADMITTED -> PLANNABLE -> SELECTED -> CONSTRUCTED -> REFUSED_AUTHORITY

  -- on TWO hosts that share no code, and BOTH terminate at
  `REFUSED_AUTHORITY` with **zero actuator calls**.

  This single fixture simultaneously demonstrates three S29 non-implications:

    * `SemanticValidity NOT=> Authority` -- the source really passes
      `AshA2A.Semantic.Admission.admit/2`;
    * `PlanValidity NOT=> Authority` -- the plan really passes
      `AshA2A.Planning.admit/2` and the package really passes
      `AshA2A.Semantic.ExecutionPackage.new/6`'s authority fence;
    * `GeneratedArtifact NOT=> DO` -- a real, content-addressed, fully
      constructed execution package is produced and still actuates nothing.

  ## The two hosts

    * **BEAM host**: the real `AshA2A.CommandBus` over a real Ash resource,
      with a real `AshA2A.Test.ActuatorCounter` GenServer as the actuator.
    * **Independent host**: `test/support/hosts/authority_host.mjs`, a real
      separate OS process (Node) that shares zero code with ash_a2a and
      re-derives the verdict from the canonical decision envelope alone. Its
      actuator is a real file append; the test asserts the file never comes
      into existence.

  Both actuators are REAL collaborators with real observable state (a process
  counter; a file on disk), not mocks. "Zero actuator calls" is therefore a
  measured fact, not an inference from a refusal tuple.

  ## Why the positive control is mandatory

  "The counter is 0" and "the file does not exist" are only evidence if both
  actuators demonstrably fire when they are supposed to. The first test in
  this module drives a correctly-authorized command through the same two
  hosts and asserts the counter reaches 1 and the file really is written.
  Without that control, every negative assertion below would be vacuous.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Decision
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Ontology, PlanningIR, Source}
  alias AshA2A.Semantic.IR
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @scenario "The agent shall actuate the authority probe on behalf of the operator."
  @host_script Path.expand("support/hosts/authority_host.mjs", __DIR__)

  setup context do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    dir =
      Path.join(
        System.tmp_dir!(),
        "sa2a-authority-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      store_opts: [name: store],
      dir: dir,
      actuator_log: Path.join(dir, "independent_host_actuations.log"),
      test: context[:test]
    }
  end

  # --------------------------------------------------------------------
  # Stage 1-4 of the chain, built from real modules only.
  # --------------------------------------------------------------------

  defp admitted_ir do
    source = Source.new(@scenario)

    {:ok, candidate_ir} =
      IR.from_map(source.id, %{
        "authority" => "none",
        "goals" => [
          %{
            "id" => "goal-actuate",
            "kind" => "goal",
            "description" => "Actuate the authority probe",
            "source_quote" => "The agent shall actuate the authority probe"
          }
        ],
        "capabilities" => [
          %{
            "id" => "cap-actuate",
            "kind" => "capability",
            "description" => "probe actuation",
            "source_quote" => "actuate the authority probe"
          }
        ]
      })

    # ADMITTED: the real deterministic admission fence, not a hand-set flag.
    {:ok, ir} = Admission.admit(source, candidate_ir)
    {source, ir}
  end

  defp constructed_chain do
    {source, ir} = admitted_ir()
    assert ir.standing == :admitted
    assert ir.authority == :none

    # PLANNABLE
    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    # SELECTED: a real plan candidate whose projected capability really
    # resolves through the canonical capability index.
    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    {:ok, selected} = AshA2A.Planning.admit(AuthorityProbe, candidate)

    # CONSTRUCTED
    {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, selected)

    %{source: source, ir: ir, selected: selected, package: package}
  end

  defp run_independent_host(envelope, dir, actuator_log, label) do
    envelope_path = Path.join(dir, "envelope-#{label}.json")
    File.write!(envelope_path, Decision.canonical_json(envelope))

    {out, 0} =
      System.cmd("node", [@host_script, envelope_path, actuator_log], stderr_to_stdout: true)

    JSON.decode!(String.trim(out))
  end

  defp node_available? do
    match?({_, 0}, System.cmd("node", ["--version"], stderr_to_stdout: true))
  rescue
    ErlangError -> false
  end

  # --------------------------------------------------------------------
  # POSITIVE CONTROL
  # --------------------------------------------------------------------

  test "CONTROL: both actuators really fire when authority IS present", %{
    store_opts: store_opts,
    dir: dir,
    actuator_log: actuator_log
  } do
    if not node_available?() do
      # A named, visible skip -- never a silent substitution of a mock host.
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-control",
        agent_id: "agent-1",
        principal_id: principal,
        authority: Authority.new(principal, @capability, token_id: "control-token"),
        input: %{}
      )

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # BEAM host
    assert {:ok, receipt} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :external_do
    assert ActuatorCounter.count() == 1

    # Independent host
    envelope = Decision.envelope(cmd, :external_do)
    result = run_independent_host(envelope, dir, actuator_log, "control")

    assert result["verdict"] == "ADMITTED"
    assert result["actuator_calls"] == 1
    assert File.exists?(actuator_log)
    assert File.read!(actuator_log) =~ @capability

    # And the two hosts agree on the decision INPUT, byte for byte.
    assert result["envelope_digest"] == Decision.digest(envelope)
  end

  # --------------------------------------------------------------------
  # THE KILLER NEGATIVE
  # --------------------------------------------------------------------

  test "ADMITTED -> PLANNABLE -> SELECTED -> CONSTRUCTED -> REFUSED_AUTHORITY on both the BEAM host and an independent host, with ZERO actuator calls (SemanticValidity NOT=> Authority, PlanValidity NOT=> Authority, GeneratedArtifact NOT=> DO)",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    chain = constructed_chain()

    # --- the chain really did get all the way to CONSTRUCTED ------------
    assert chain.ir.standing == :admitted
    assert chain.selected.admitted_skills != []
    assert %ExecutionPackage{standing: :candidate, authority: :none} = chain.package
    assert chain.package.fingerprint =~ ~r/^[0-9a-f]{64}$/

    # ... and every stage's ceiling is `authority: :none`. Nothing along the
    # manufacturing chain can raise it; that is the S28 ceiling.
    assert chain.ir.authority == :none
    assert chain.selected.authority == :none
    assert chain.package.semantic_ir.authority == :none
    assert chain.package.plan_candidate.authority == :none

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-refused",
        agent_id: "agent-1",
        principal_id: principal,
        # No authority. Everything else about this request is impeccable.
        authority: nil,
        input: %{},
        metadata: %{
          execution_package: chain.package.fingerprint,
          plan: chain.selected.fingerprint,
          semantic_source: chain.source.id
        }
      )

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # --- BEAM host terminates at REFUSED_AUTHORITY ----------------------
    assert {:error, %{code: :authority_required, detail: "authority_required"}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    assert ActuatorCounter.count() == 0

    # --- independent host terminates at REFUSED_AUTHORITY ---------------
    envelope = Decision.envelope(cmd, :external_do)
    result = run_independent_host(envelope, dir, actuator_log, "refused")

    assert result["host"] == "node"
    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_required"
    assert result["actuator_calls"] == 0

    # --- ZERO actuator calls, on both hosts, measured ---------------------
    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)

    # --- both hosts saw the same decision input -------------------------
    assert result["envelope_digest"] == Decision.digest(envelope)
  end

  test "the same constructed package presented with a MISMATCHED authority also terminates at REFUSED_AUTHORITY on both hosts with zero actuation",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    chain = constructed_chain()
    assert %ExecutionPackage{authority: :none} = chain.package

    principal = Identity.principal("operator-1")

    cmd =
      Command.new(@capability,
        command_id: "killer-mismatch",
        agent_id: "agent-1",
        principal_id: principal,
        # Real authority -- for a DIFFERENT principal. Presenting someone
        # else's valid grant is not authority.
        authority:
          Authority.new(Identity.principal("someone-else"), @capability,
            token_id: "borrowed-token"
          ),
        input: %{},
        metadata: %{execution_package: chain.package.fingerprint}
      )

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    envelope = Decision.envelope(cmd, :external_do)
    result = run_independent_host(envelope, dir, actuator_log, "mismatch")

    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_mismatch"
    assert result["actuator_calls"] == 0

    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)
  end

  test "an EXPIRED authority terminates at REFUSED_AUTHORITY identically on both hosts, decided against the envelope's own instant (no clock skew between hosts)",
       %{store_opts: store_opts, dir: dir, actuator_log: actuator_log} do
    if not node_available?() do
      flunk("node is not available on this machine; the independent host cannot be exercised")
    end

    principal = Identity.principal("operator-1")
    expires_at = DateTime.add(DateTime.utc_now(), -60, :second)

    cmd =
      Command.new(@capability,
        command_id: "killer-expired",
        agent_id: "agent-1",
        principal_id: principal,
        authority:
          Authority.new(principal, @capability,
            token_id: "expired-token",
            expires_at: expires_at
          ),
        input: %{}
      )

    assert {:error, %{code: :authority_mismatch}} =
             CommandBus.run(cmd, data_message(%{}), AuthorityProbe, store_opts: store_opts)

    # The independent host decides expiry from the envelope's own
    # `evaluated_at`, so it needs no synchronized clock to agree.
    envelope = Decision.envelope(cmd, :external_do)
    result = run_independent_host(envelope, dir, actuator_log, "expired")

    assert result["verdict"] == "REFUSED_AUTHORITY"
    assert result["code"] == "authority_mismatch"
    assert result["actuator_calls"] == 0
    assert ActuatorCounter.count() == 0
    refute File.exists?(actuator_log)
  end
end
