defmodule AshA2A.Semantic.FeedbackTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{Admission, ExecutionPackage, Feedback, IR, Ontology, PlanningIR, Source}

  test "projects runtime receipt evidence back into the loop without authority" do
    source = Source.new("Echo capability should read a record.")

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
          "description" => "Read the Echo record.",
          "source_quote" => "Echo capability should read a record."
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)

    assert {:ok, ontology} = Ontology.from_ir(ir)
    assert {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)

    plan_candidate =
      Candidate.new(:semantic_synthesis, %{"hddl" => "", "fond" => ""}, ["Echo.read"],
        formalism: :hddl_fond
      )

    assert {:ok, package} =
             ExecutionPackage.new(source, ir, ontology, planning_ir, plan_candidate)

    receipt = %Receipt{
      receipt_id: Identity.runtime("receipt-1"),
      command_id: Identity.command("command-1"),
      execution_id: Identity.execution("execution-1"),
      agent_id: Identity.agent("agent-1"),
      principal_id: Identity.principal("principal-1"),
      capability_id: "Echo.read",
      fingerprint: "command-fingerprint",
      consequence: :read,
      status: :completed,
      standing: :observed,
      recorded_at: ~U[2026-09-13 20:00:00Z]
    }

    assert {:ok, feedback} = Feedback.from_receipt(package, receipt)
    assert feedback.standing == :observed
    assert feedback.authority == :none
    assert feedback.observation["status"] == "completed"
  end
end
