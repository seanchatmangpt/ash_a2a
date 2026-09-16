defmodule AshA2A.Semantic.AttestationTest do
  @moduledoc """
  RFC-SA2A-001 S33 semantic attestation, built from receipts a real
  `AshA2A.CommandBus.run/4` actually produced.
  """
  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, SemanticSubject}
  alias AshA2A.Semantic.Attestation
  alias AshA2A.Test.Fixture.{ActuationCounter, CountingActuator, Echo}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(ActuationCounter)
    store = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})
    %{store_opts: [name: store]}
  end

  defp sha(seed),
    do: "sha256:" <> (seed |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))

  defp fully_specified_run(command_id, store_opts) do
    principal = Identity.principal("attest-principal")
    authority = Authority.new(principal, @capability, token_id: "attest-auth")

    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: sha("attest-graph"),
        projection_digest: sha("attest-projection"),
        manufacturer_digest: sha("attest-manufacturer")
      )

    effect_key = "attest-#{System.unique_integer([:positive])}"

    command =
      Command.new(@capability,
        command_id: command_id,
        agent_id: "attest-agent",
        principal_id: principal,
        authority: authority,
        semantic_subject: subject,
        input: %{effect_key: effect_key}
      )

    {:ok, receipt} =
      CommandBus.run(command, data_message(%{"effect_key" => effect_key}), CountingActuator,
        store_opts: store_opts,
        plan_digest: sha("attest-plan")
      )

    receipt
  end

  test "an attestation identifies every S33 revision from a real execution", %{
    store_opts: store_opts
  } do
    receipt = fully_specified_run("attest-1", store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([receipt])

    assert attestation.semantic_revision == sha("attest-graph")
    assert attestation.plan_revision == sha("attest-plan")
    assert attestation.manufacturer_revision == sha("attest-manufacturer")
    assert attestation.projected_artifact_digest == sha("attest-projection")

    assert %{decision: :admitted, capability_id: @capability, token_id: "runtime:attest-auth"} =
             attestation.authority_decision

    assert [%{receipt_id: receipt_id, terminal_status: :executed}] = attestation.receipt_set
    assert receipt_id == Identity.external(receipt.receipt_id)
    assert String.starts_with?(attestation.receipt_set_digest, "sha256:")

    assert attestation.observed_post_state.status == :completed
    assert attestation.observed_post_state.terminal_status == :executed
    assert attestation.observed_post_state.consequence == :external_do

    # Everything claimable was observed, so nothing is listed as unobserved.
    assert attestation.unobserved == []
    assert Enum.all?(Attestation.claimable_fields(), &Attestation.claims?(attestation, &1))

    assert :ok = Attestation.verify(attestation, [receipt])
  end

  test "an attestation over a command with no semantic subject claims nothing it did not observe",
       %{store_opts: store_opts} do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "attest-thin-1",
        agent_id: "attest-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([receipt])

    # The fields that were genuinely not observed are nil AND named.
    assert attestation.semantic_revision == nil
    assert attestation.plan_revision == nil
    assert attestation.manufacturer_revision == nil
    assert attestation.projected_artifact_digest == nil

    for field <- [
          :semantic_revision,
          :plan_revision,
          :manufacturer_revision,
          :projected_artifact_digest
        ] do
      assert field in attestation.unobserved
      refute Attestation.claims?(attestation, field)
    end

    # The fields that WERE observed are still claimed -- absence of one
    # revision does not void the attestation.
    assert Attestation.claims?(attestation, :observed_post_state)
    assert Attestation.claims?(attestation, :authority_decision)
    assert attestation.authority_decision.decision == :not_required

    assert :ok = Attestation.verify(attestation, [receipt])
  end

  test "an attestation edited to claim evidence the receipts never carried fails verify/2", %{
    store_opts: store_opts
  } do
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "attest-forged-1",
        agent_id: "attest-agent",
        principal_id: "anonymous",
        input: %{}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

    assert {:ok, honest} = Attestation.from_receipts([receipt])
    assert :ok = Attestation.verify(honest, [receipt])

    # Someone edits in a semantic revision that no receipt ever carried.
    forged = %{honest | semantic_revision: sha("a-graph-that-was-never-executed")}

    assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :semantic_revision}} =
             Attestation.verify(forged, [receipt])

    # And the internal contradiction (a value sitting in a field still listed
    # as unobserved) is caught too.
    assert :semantic_revision in forged.unobserved

    forged_plan = %{honest | plan_revision: sha("a-plan-that-never-ran")}

    assert {:error, %{code: :attestation_claims_unobserved_evidence, detail: :plan_revision}} =
             Attestation.verify(forged_plan, [receipt])
  end

  test "an attestation verified against a different receipt set is refused", %{
    store_opts: store_opts
  } do
    first = fully_specified_run("attest-set-1", store_opts)
    second = fully_specified_run("attest-set-2", store_opts)

    assert {:ok, attestation} = Attestation.from_receipts([first])

    assert {:error, %{code: :attestation_receipt_set_mismatch}} =
             Attestation.verify(attestation, [second])
  end

  test "an attestation requires at least one receipt and one actuation" do
    assert {:error, %{code: :attestation_without_receipts}} = Attestation.from_receipts([])

    assert {:error, %{code: :attestation_requires_receipts}} =
             Attestation.from_receipts([%{not: :a_receipt}])
  end

  test "an attestation spanning two different actuations is refused", %{store_opts: store_opts} do
    first = fully_specified_run("attest-multi-1", store_opts)
    second = fully_specified_run("attest-multi-2", store_opts)

    refute first.actuation_id == second.actuation_id

    assert {:error, %{code: :attestation_spans_multiple_actuations, detail: ids}} =
             Attestation.from_receipts([first, second])

    assert length(ids) == 2
  end

  test "the attestation evidence class is the WEAKEST across the receipt set, never the strongest" do
    base = %Receipt{
      receipt_id: Identity.runtime("r-1"),
      command_id: Identity.command("c-1"),
      execution_id: Identity.execution("e-1"),
      agent_id: Identity.agent("a-1"),
      principal_id: Identity.principal("p-1"),
      capability_id: "Cap.act",
      fingerprint: "fp",
      consequence: :external_do,
      status: :completed,
      standing: :observed,
      recorded_at: DateTime.utc_now(),
      actuation_id: Identity.actuation("act-1"),
      idempotency_key: Identity.idempotency("idem-1"),
      actor: Identity.principal("p-1"),
      intended_effect: %{capability_id: "Cap.act", consequence: :external_do},
      input_digest: "sha256:abc",
      logical_clock: 1,
      terminal_status: :executed
    }

    weak = %{base | evidence_class: AshA2A.Evidence.LocalTest.new(%{run: 1}), logical_clock: 1}

    strong = %{
      base
      | receipt_id: Identity.runtime("r-2"),
        evidence_class: AshA2A.Evidence.Merge.new(%{pr: 9}),
        logical_clock: 2
    }

    assert {:ok, attestation} = Attestation.from_receipts([strong, weak])
    assert attestation.evidence_class.__struct__ == AshA2A.Evidence.LocalTest
  end
end
