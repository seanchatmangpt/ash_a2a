defmodule AshA2A.Gall.ProcessInterventionTest do
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, Identity, SemanticSubject}
  alias AshA2A.Gall.ProcessIntervention
  alias AshA2A.ReceiptStore
  alias AshA2A.Test.Fixture.{Item, ItemDomain}

  defp finding(capability_id, overrides \\ %{}) do
    base = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      evidence_digest: "sha256:" <> String.duplicate("b", 64),
      semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
      finding_class: "conformance",
      finding_type: "ordering_violation",
      horizon: "FAST",
      candidate_class: "bounded_intervention",
      vocabulary: "https://w3id.org/ocel",
      requested_capability_id: "attacker-supplied-value-is-not-authority"
    }

    opts = [
      allowed_producers: %{"seanchatmangpt/beam4pm" => String.duplicate("a", 40)},
      public_vocabulary: ["https://w3id.org/ocel"],
      admission_rules: %{
        {"https://w3id.org/ocel", "ordering_violation", "bounded_intervention"} => capability_id
      }
    ]

    {Map.merge(base, overrides), opts}
  end

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  test "GALL-029 capability comes only from explicit semantic admission rule" do
    capability = AshA2A.CapabilityIndex.Compiler.capability_id(Item, :create)
    {source, opts} = finding(capability)

    assert {:ok, candidate} = ProcessIntervention.admit(source, opts)
    assert candidate.capability_id == capability
    assert candidate.authority == :none
    assert candidate.evidence_ceiling == "ADMIT_ONLY"
    refute candidate.capability_id == source.requested_capability_id

    assert {:error, :unsupported_process_finding_rule} =
             ProcessIntervention.admit(source, Keyword.put(opts, :admission_rules, %{}))

    assert {:error, :secret_bearing_finding} =
             ProcessIntervention.admit(Map.put(source, :authorization, "Bearer abc"), opts)
  end

  test "GALL-030 requires authority and one exact scoped input, then replay stays one effect",
       %{store_opts: store_opts} do
    capability = AshA2A.CapabilityIndex.Compiler.capability_id(Item, :create)
    {source, admission_opts} = finding(capability)
    {:ok, candidate} = ProcessIntervention.admit(source, admission_opts)

    label = "gall-030-#{System.unique_integer([:positive])}"
    input = %{label: label}
    message = data_message(input)
    principal = Identity.principal("gall-030-principal")

    {:ok, semantic_subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("1", 64),
        projection_digest: "sha256:" <> String.duplicate("2", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("3", 64)
      )

    base_command_opts = [
      command_id: "gall-030-command",
      agent_id: "gall-030-agent",
      principal_id: principal,
      semantic_subject: semantic_subject,
      input: input,
      metadata: %{
        gall_029_candidate_digest: candidate.candidate_digest,
        idempotency_key: "gall-030-one-effect"
      }
    ]

    no_authority = Command.new(capability, base_command_opts)
    observer = fn cand, receipt ->
      {:ok,
       %{
         independent: true,
         candidate_digest: cand.candidate_digest,
         command_id: Identity.external(receipt.command_id),
         postcondition: "verified",
         expected_postcondition_digest:
           ProcessIntervention.canonical_digest(%{item_with_label_exists: true})
       }}
    end

    scope = %{input_digest: ProcessIntervention.canonical_digest(input)}

    assert {:error, :authority_required} =
             ProcessIntervention.intervene(
               candidate,
               no_authority,
               message,
               ItemDomain,
               store: ReceiptStore.Memory,
               store_opts: store_opts,
               actuation_dedup: :strict,
               independent_observer: observer,
               scope: scope,
               max_consequences: 1,
               expected_postcondition: %{item_with_label_exists: true}
             )

    refute Enum.any?(Ash.read!(Item, domain: ItemDomain), &(&1.label == label))

    authority = Authority.new(principal, capability, token_id: "gall-030-grant")
    command = Command.new(capability, Keyword.put(base_command_opts, :authority, authority))

    call = fn ->
      ProcessIntervention.intervene(
        candidate,
        command,
        message,
        ItemDomain,
        store: ReceiptStore.Memory,
        store_opts: store_opts,
        actuation_dedup: :strict,
        independent_observer: observer,
        scope: scope,
        max_consequences: 1,
        expected_postcondition: %{item_with_label_exists: true}
      )
    end

    assert {:ok, first} = call.()
    assert first.evidence_ceiling == "AUTHORIZED_DO"
    assert first.postcondition_standing == "VERIFIED"
    assert length(Enum.filter(Ash.read!(Item, domain: ItemDomain), &(&1.label == label))) == 1

    assert {:ok, replay} = call.()
    assert replay.command_receipt.replayed? == true
    assert length(Enum.filter(Ash.read!(Item, domain: ItemDomain), &(&1.label == label))) == 1

    assert {:error, :intervention_budget_must_be_one} =
             ProcessIntervention.intervene(
               candidate,
               command,
               message,
               ItemDomain,
               store: ReceiptStore.Memory,
               store_opts: store_opts,
               actuation_dedup: :strict,
               independent_observer: observer,
               scope: scope,
               max_consequences: 2,
               expected_postcondition: %{item_with_label_exists: true}
             )
  end
end
