defmodule AshA2A.Gall.ProcessAutonomicsTest do
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Identity, Postcondition, ReceiptStore}
  alias AshA2A.Gall.{ProcessFinding, ProcessIntervention}
  alias AshA2A.Test.Fixture.Item

  defmodule ItemPostcondition do
    @behaviour AshA2A.Postcondition

    @impl true
    def verify(%{label: label}, _probe) do
      items = Ash.read!(AshA2A.Test.Fixture.Item)

      if Enum.any?(items, &(&1.label == label)) do
        {:verified, %{"label" => label, "source" => "independent_ash_read"}}
      else
        {:contradicted, %{"label" => label, "source" => "independent_ash_read"}}
      end
    end
  end

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "GALL-029 admits an exact public process finding as candidate-only evidence" do
    assert {:ok, admitted} =
             finding()
             |> ProcessFinding.admit(
               expected_repository: "seanchatmangpt/beam4pm",
               expected_producer_sha: producer_sha(),
               expected_semantic_subject: "semantic:checkout",
               expected_process_subject: "process:checkout"
             )

    assert admitted.admission_receipt["standing"] == "CANDIDATE"
    assert admitted.admission_receipt["authority"] == "NONE"
    assert String.starts_with?(admitted.admission_receipt["finding_digest"], "sha256:")

    assert ProcessFinding.canonical_digest(%{"b" => 2, "a" => 1}) ==
             ProcessFinding.canonical_digest(%{"a" => 1, "b" => 2})
  end

  test "GALL-029 refuses stale producer identity and private ontology inputs" do
    assert {:error, {:refused_process_finding, :stale_or_mismatched_subject, _}} =
             ProcessFinding.admit(finding(), expected_producer_sha: String.duplicate("f", 40))

    assert {:error, {:refused_process_finding, :private_ontology, _}} =
             finding(%{"ontology_scope" => "private"}) |> ProcessFinding.admit()
  end

  test "GALL-030 requires exact authority constraints and an independent postcondition before DO", %{
    store_opts: store_opts
  } do
    label = "gall-#{System.unique_integer([:positive])}"
    scope = %{"tenant" => "global"}
    budget = %{"writes" => 1}
    capability = "AshA2A.Test.Fixture.Item.create"
    target = inspect(Item)
    principal = Identity.principal("gall-user")

    assert {:ok, admitted} = ProcessFinding.admit(finding())

    assert {:ok, candidate} =
             ProcessIntervention.construct(admitted,
               capability_id: capability,
               target: target,
               principal_id: principal,
               agent_id: "gall-agent",
               command_id: "gall-command-#{label}",
               scope: scope,
               budget: budget,
               input: %{label: label}
             )

    assert candidate.authority == "NONE"
    assert candidate.standing == "CANDIDATE"
    assert candidate.command.authority == nil

    bad_authority =
      Authority.new(principal, capability,
        token_id: "gall-bad-authority",
        constraints: %{target: target, scope: scope, budget: %{"writes" => 2}}
      )

    assert {:error,
            %{
              code: :process_intervention_refused,
              standing: "REFUSED",
              detail: {:authority_constraint_mismatch, :budget, ^budget, %{"writes" => 2}}
            }} =
             ProcessIntervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               bad_authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    authority =
      Authority.new(principal, capability,
        token_id: "gall-authority",
        constraints: %{target: target, scope: scope, budget: budget}
      )

    assert {:error,
            %{
              code: :process_intervention_refused,
              standing: "REFUSED",
              detail: :postcondition_required
            }} =
             ProcessIntervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts
             )

    assert {:ok, %{standing: "COMPLETED", receipt: receipt}} =
             ProcessIntervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    assert receipt.status == :completed
    assert get_in(receipt.metadata, [:postcondition, :status]) == :verified
    assert receipt.actuation_id
    assert receipt.idempotency_key
    assert receipt.plan_digest == candidate.finding_digest
    assert receipt.intended_effect.gall_finding_digest == candidate.finding_digest
    assert receipt.intended_effect.target == target
    assert receipt.intended_effect.scope == scope
    assert receipt.intended_effect.budget == budget

    assert {:ok, stored} = ReceiptStore.Memory.fetch(candidate.command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id

    assert {:ok, %{standing: "COMPLETED", receipt: replay}} =
             ProcessIntervention.execute(
               candidate,
               data_message(%{"label" => label}),
               Item,
               authority,
               store_opts: store_opts,
               postcondition: %Postcondition{
                 id: "item-created",
                 verifier: ItemPostcondition,
                 expect: %{label: label}
               }
             )

    assert replay.replayed?
    assert replay.receipt_id == receipt.receipt_id
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => "gall.process-finding/v26.9.18",
        "producer" => %{
          "repository" => "seanchatmangpt/beam4pm",
          "sha" => producer_sha(),
          "receipt_digest" => digest("a")
        },
        "evidence_digest" => digest("b"),
        "evidence_class" => "process-conformance",
        "semantic_subject" => "semantic:checkout",
        "process_subject" => "process:checkout",
        "finding_type" => "conformance_delta",
        "horizon" => "event-time:2026-09-19T00:00:00Z/2026-09-20T00:00:00Z",
        "requested_candidate_class" => "construct_command",
        "authority" => "NONE"
      },
      overrides
    )
  end

  defp producer_sha, do: "0123456789abcdef0123456789abcdef01234567"
  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)
end
