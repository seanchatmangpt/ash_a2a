defmodule AshA2A.Semantic.FeedbackTest do
  use ExUnit.Case, async: true

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Semantic.{ExecutionPackage, Feedback}

  test "projects runtime receipt evidence back into the loop without authority" do
    package = %ExecutionPackage{
      source: nil,
      semantic_ir: nil,
      ontology: nil,
      planning_ir: nil,
      plan_candidate: nil,
      fingerprint: "package-1"
    }

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
