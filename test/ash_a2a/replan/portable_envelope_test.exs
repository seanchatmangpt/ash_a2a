defmodule AshA2A.Replan.PortableEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.PortableEnvelope

  test "failed receipt carries the SA2A replan decision with no authority" do
    assert {:ok,
            %{
              "exact_subject" => "sha256:subject",
              "consequence" => "failed",
              "decision" => %{
                "kind" => "replan",
                "reason" => "failed",
                "authority" => "none"
              }
            }} =
             PortableEnvelope.from_receipt(
               %{
                 semantic_subject: "sha256:subject",
                 receipt_id: "r1",
                 terminal_status: :failed
               },
               :gymact
             )
  end

  test "unknown receipt carries reconcile-before-replan rather than consumer guesswork" do
    assert {:ok,
            %{
              "consequence" => "unknown_outcome",
              "decision" => %{
                "kind" => "replan",
                "reason" => "unknown_outcome_reconcile_first",
                "authority" => "none"
              }
            }} =
             PortableEnvelope.from_receipt(%{
               semantic_subject: "sha256:subject",
               receipt_id: "r2",
               terminal_status: :new_provider_verdict
             })
  end

  test "reconciled and compensated receipts stop instead of replan" do
    for status <- [:reconciled, :compensated] do
      assert {:ok,
              %{
                "consequence" => consequence,
                "decision" => %{"kind" => "stop", "authority" => "none"}
              }} =
               PortableEnvelope.from_receipt(%{
                 semantic_subject: "sha256:subject",
                 receipt_id: "r-terminal-" <> Atom.to_string(status),
                 terminal_status: status
               })

      assert consequence == Atom.to_string(status)
    end
  end

  test "refused receipt carries stop and remains powerless" do
    assert {:ok,
            %{
              "consequence" => "refused",
              "decision" => %{"kind" => "stop", "authority" => "none"}
            }} =
             PortableEnvelope.from_receipt(%{
               semantic_subject: "sha256:subject",
               receipt_id: "r3",
               terminal_status: :refused
             })
  end
end
