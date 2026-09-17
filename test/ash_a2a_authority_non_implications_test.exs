defmodule AshA2A.AuthorityNonImplicationsTest do
  @moduledoc """
  RFC-SA2A-001 S29: the eight non-implications, each as its own individually
  named, executable falsifier against the REAL `AshA2A.CommandBus` and the
  REAL `AshA2A.Authority` -- no mocks, no stubbed collaborators, real Ash
  resources, real receipt store, real counting actuator.

      Identity           NOT=> Authority
      Authentication     NOT=> Authority
      Capability         NOT=> Authority
      TaskAssignment     NOT=> Authority
      PlanValidity       NOT=> Authority
      Proof              NOT=> Authority
      ModelConfidence    NOT=> Authority
      AgentCardDeclaration NOT=> Authority

  Each test builds the STRONGEST available form of its antecedent (a real
  verified transport identity, a capability that really resolves through
  `AshA2A.Info`, a plan that really passes `AshA2A.Planning.admit/2`, a proof
  digest this test really verifies, and so on), then asserts the bus still
  refuses AND that the real actuator count is still 0.

  Several of these hold structurally in the pre-existing code
  (`CommandBus.admit/2` consults only `AshA2A.Authority.admits?/2`, which
  compares subject and capability and nothing else). That is exactly why they
  are written down here: an implicit property nobody asserts is one refactor
  away from silently disappearing. See the "already held / newly enforced"
  notes on each test.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Authority.Decision
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Ontology, PlanningIR, Source}
  alias AshA2A.Semantic.IR
  alias AshA2A.Test.ActuatorCounter
  alias AshA2A.Test.Fixture.AuthorityProbe

  @capability "AshA2A.Test.Fixture.AuthorityProbe.actuate"
  @observe_capability "AshA2A.Test.Fixture.AuthorityProbe.peek"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuatorCounter)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp run(command, store_opts) do
    CommandBus.run(command, data_message(%{}), AuthorityProbe, store_opts: store_opts)
  end

  defp command(opts) do
    Command.new(
      Keyword.get(opts, :capability_id, @capability),
      Keyword.merge(
        [
          agent_id: "agent-under-test",
          principal_id: "principal-under-test",
          input: %{}
        ],
        opts
      )
      |> Keyword.delete(:capability_id)
    )
  end

  # --------------------------------------------------------------------
  # Control: the actuator and the whole dispatch path really do work.
  # Without this, every "count == 0" assertion below would be vacuous.
  # --------------------------------------------------------------------

  test "CONTROL: a correctly authorized command really does reach the actuator (so count==0 elsewhere is a real observation)",
       %{store_opts: store_opts} do
    principal = Identity.principal("principal-under-test")

    cmd =
      command(
        command_id: "control-admitted",
        authority: Authority.new(principal, @capability, token_id: "control-token")
      )

    assert ActuatorCounter.count() == 0
    assert {:ok, receipt} = run(cmd, store_opts)
    assert receipt.status == :completed
    assert receipt.consequence == :external_do

    # Real state, not "was it called": the counter really advanced.
    assert ActuatorCounter.count() == 1
  end

  # --------------------------------------------------------------------
  # 1. Identity NOT=> Authority
  # --------------------------------------------------------------------

  test "Identity NOT=> Authority: a real, well-formed principal Identity on a real consequence-bearing capability is refused with zero actuation",
       %{store_opts: store_opts} do
    # ALREADY HELD structurally (`CommandBus.admit/2` has an
    # `:authority_required` clause); newly made an explicit falsifier here.
    principal = Identity.principal("principal-under-test")
    assert %Identity{kind: :principal, value: "principal-under-test"} = principal

    cmd = command(command_id: "identity-1", principal_id: principal, authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
    assert :error = ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
  end

  # --------------------------------------------------------------------
  # 2. Authentication NOT=> Authority
  # --------------------------------------------------------------------

  test "Authentication NOT=> Authority: a transport-VERIFIED identity carrying authority for one capability cannot act on another",
       %{store_opts: store_opts} do
    # This is the strongest available form of "authenticated": the exact
    # constructor the A2A adapter uses for an identity `A2A.Plug.Auth` has
    # already verified. It really does produce `source: :transport_verified`.
    authenticated = Authority.from_verified_identity("principal-under-test", @observe_capability)

    assert %Authority{source: :transport_verified} = authenticated
    assert authenticated.subject == Identity.principal("principal-under-test")

    cmd = command(command_id: "authn-1", authority: authenticated)

    # Authenticated, and authenticated *for a capability on this very
    # resource* -- still refused for the consequence-bearing one.
    assert {:error, %{code: :authority_mismatch}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 3. Capability NOT=> Authority
  # --------------------------------------------------------------------

  test "Capability NOT=> Authority: a capability that really resolves through AshA2A.Info is still refused without authority",
       %{store_opts: store_opts} do
    # The antecedent is real and checked, not assumed: the capability
    # genuinely resolves to a real skill over a real compiled resource.
    assert {:ok, skill} = AshA2A.Info.skill(AuthorityProbe, @capability)
    assert skill.consequence == :external_do
    assert skill.resource == AuthorityProbe

    cmd = command(command_id: "capability-1", authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 4. TaskAssignment NOT=> Authority
  # --------------------------------------------------------------------

  test "TaskAssignment NOT=> Authority: a command bound to a real task identity is refused exactly as an unassigned one is",
       %{store_opts: store_opts} do
    task = Identity.task("task-really-assigned-to-this-agent")
    cmd = command(command_id: "task-1", task_id: task, authority: nil)

    assert cmd.task_id == task
    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0

    # And assignment does not even perturb the refusal: the decision is
    # byte-identical with and without the task binding.
    without_task = command(command_id: "task-2", authority: nil)

    assert Decision.verdict(Decision.envelope(cmd, AuthorityProbe)) ==
             Decision.verdict(Decision.envelope(without_task, AuthorityProbe))
  end

  # --------------------------------------------------------------------
  # 5. PlanValidity NOT=> Authority
  # --------------------------------------------------------------------

  test "PlanValidity NOT=> Authority: a plan that really passes AshA2A.Planning.admit/2 confers nothing on the bus",
       %{store_opts: store_opts} do
    # A genuinely admitted plan candidate over the canonical capability --
    # `Planning.admit/2` resolves every projected capability id through the
    # real capability index and refuses noncanonical ones.
    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    assert {:ok, admitted} = AshA2A.Planning.admit(AuthorityProbe, candidate)
    assert [%AshA2A.Skill{}] = admitted.admitted_skills

    # The admitted plan's own standing is the ceiling: candidate, authority
    # :none. Planning cannot raise it -- that is structurally enforced.
    assert admitted.standing == :candidate
    assert admitted.authority == :none

    cmd = command(command_id: "plan-1", authority: nil, metadata: %{plan: admitted.fingerprint})

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  test "PlanValidity NOT=> Authority: a fully CONSTRUCTED semantic execution package is still authority: :none",
       %{store_opts: store_opts} do
    package = constructed_package()

    # Real, constructed, content-addressed manufacturing output ...
    assert %ExecutionPackage{standing: :candidate, authority: :none} = package
    assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/

    # ... and it still buys exactly nothing at the consequence boundary.
    cmd =
      command(
        command_id: "package-1",
        authority: nil,
        metadata: %{execution_package: package.fingerprint}
      )

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 6. Proof NOT=> Authority
  # --------------------------------------------------------------------

  test "Proof NOT=> Authority: a cryptographic proof this test independently VERIFIES does not admit the command",
       %{store_opts: store_opts} do
    payload = "authority-probe-actuation-request"

    proof =
      payload
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    # The proof is real and really checks out -- the antecedent is genuinely
    # true here, not a placeholder string.
    assert proof ==
             :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    assert String.length(proof) == 64

    cmd =
      command(
        command_id: "proof-1",
        authority: nil,
        metadata: %{proof: proof, proof_algorithm: "sha256", proof_payload: payload}
      )

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # 7. ModelConfidence NOT=> Authority
  # --------------------------------------------------------------------

  test "ModelConfidence NOT=> Authority: confidence 1.0 is refused identically to confidence 0.0",
       %{store_opts: store_opts} do
    certain = command(command_id: "confidence-1", authority: nil, metadata: %{confidence: 1.0})
    unsure = command(command_id: "confidence-2", authority: nil, metadata: %{confidence: 0.0})

    assert {:error, %{code: :authority_required}} = run(certain, store_opts)
    assert {:error, %{code: :authority_required}} = run(unsure, store_opts)
    assert ActuatorCounter.count() == 0

    # Confidence is not even an input to the decision: it does not appear in
    # the canonical decision envelope at all, so the two commands -- which
    # differ ONLY in stated confidence -- are literally the same decision
    # input, byte for byte.
    at = ~U[2026-01-01 00:00:00Z]

    assert certain.metadata != unsure.metadata

    assert Decision.digest(Decision.envelope(certain, AuthorityProbe, evaluated_at: at)) ==
             Decision.digest(Decision.envelope(unsure, AuthorityProbe, evaluated_at: at))
  end

  # --------------------------------------------------------------------
  # 8. AgentCardDeclaration NOT=> Authority
  # --------------------------------------------------------------------

  test "AgentCardDeclaration NOT=> Authority: a skill really published on the real A2A agent card is still refused",
       %{store_opts: store_opts} do
    card = AshA2A.Info.agent_card(AuthorityProbe)

    # The antecedent is real: the capability genuinely is advertised.
    declared_ids = Enum.map(card.skills, & &1.id)
    assert @capability in declared_ids

    cmd = command(command_id: "card-1", authority: nil)

    assert {:error, %{code: :authority_required}} = run(cmd, store_opts)
    assert ActuatorCounter.count() == 0
  end

  # --------------------------------------------------------------------
  # Pinning: the portable decision function must not drift from the bus.
  # --------------------------------------------------------------------

  describe "AshA2A.Authority.Decision is pinned to the real CommandBus" do
    test "every non-implication case yields the same typed outcome from the bus and from the portable evaluator",
         %{store_opts: store_opts} do
      principal = Identity.principal("principal-under-test")

      cases = [
        {:authority_required, command(command_id: "pin-1", authority: nil)},
        {:authority_mismatch,
         command(
           command_id: "pin-2",
           authority: Authority.new(principal, @observe_capability, token_id: "pin-wrong-cap")
         )},
        {:authority_mismatch,
         command(
           command_id: "pin-3",
           authority:
             Authority.new(Identity.principal("someone-else"), @capability,
               token_id: "pin-wrong-subject"
             )
         )},
        {:admitted,
         command(
           command_id: "pin-4",
           authority: Authority.new(principal, @capability, token_id: "pin-ok")
         )}
      ]

      for {expected, cmd} <- cases do
        bus = run(cmd, store_opts)
        portable = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))

        case expected do
          :admitted ->
            assert {:ok, %AshA2A.Receipt{}} = bus
            assert {:admitted, %{code: :authority_admitted}} = portable

          code ->
            assert {:error, %{code: ^code}} = bus
            assert {:refused, %{code: ^code}} = portable
        end
      end
    end

    test "an observe-consequence capability needs no authority on both the bus and the portable evaluator",
         %{store_opts: store_opts} do
      cmd = command(command_id: "pin-observe", capability_id: @observe_capability, authority: nil)

      assert {:ok, receipt} = run(cmd, store_opts)
      assert receipt.consequence == :observe
      assert {:admitted, _} = Decision.verdict(Decision.envelope(cmd, AuthorityProbe))
    end
  end

  # --------------------------------------------------------------------

  defp constructed_package do
    source = Source.new("The agent shall actuate the authority probe.")

    # Real admission, not a hand-set `standing: :admitted`: IR.from_map/2
    # builds a genuine :candidate IR and Admission.admit/2 runs its full
    # check chain for real, so the returned IR carries a real
    # AshA2A.Semantic.IrAdmissionSeal-minted seal (see that module's docs).
    payload = %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Actuate the probe",
          "source_quote" => "The agent shall actuate the authority probe."
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)

    {:ok, ontology} = Ontology.from_ir(ir)
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    candidate =
      Candidate.new(:test_planner, %{"capability_id" => @capability}, [@capability],
        formalism: :hddl_fond
      )

    {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)
    package
  end
end
