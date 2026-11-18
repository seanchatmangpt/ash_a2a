# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.ProcessInterventionTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, Identity, Postcondition, ReceiptStore}
  alias AshA2A.Gall.ProcessIntervention
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Fixtures
  alias AshA2A.Chicago.Fixtures.Postcondition.{Ledger, LedgerVerifier}

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    handler = "gall-process-intervention-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:ash_a2a, :command_bus, :actuate, :start],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:actuate_start, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{store_opts: [name: name]}
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        producer_repository: "seanchatmangpt/beam4pm",
        producer_sha: String.duplicate("a", 40),
        evidence_digest: "sha256:" <> String.duplicate("b", 64),
        semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
        finding_class: "conformance",
        finding_type: "ordering_violation",
        candidate_class: "bounded_intervention",
        horizon: "FAST",
        vocabulary: "https://w3id.org/ocel",
        requested_capability_id: Fixtures.capability(:honest_write)
      },
      overrides
    )
  end

  defp rule_key(finding), do: {finding.vocabulary, finding.finding_type, finding.candidate_class}

  defp admission_opts(finding, overrides \\ []) do
    capability = Fixtures.capability(:honest_write)

    [
      allowed_producers: [finding.producer_sha],
      allowed_evidence_digests: [finding.evidence_digest],
      allowed_semantic_subjects: [finding.semantic_subject_digest],
      allowed_horizons: [finding.horizon],
      allowed_capabilities: [capability],
      public_vocabulary: [finding.vocabulary],
      admission_rules: %{rule_key(finding) => capability}
    ]
    |> Keyword.merge(overrides)
  end

  defp admit!(finding) do
    assert {:ok, candidate} = ProcessIntervention.admit(finding, admission_opts(finding))
    candidate
  end

  defp intervention(candidate, key, store_opts, opts \\ []) do
    principal = Identity.principal("gall-030")
    capability = candidate.capability_id

    authority =
      if Keyword.get(opts, :authorized, true) do
        Keyword.get_lazy(opts, :authority, fn ->
          Authority.new(principal, capability, token_id: "auth-#{key}")
        end)
      end

    digest = Keyword.get(opts, :candidate_digest, candidate.candidate_digest)
    input = %{key: key, value: "X"}

    metadata =
      %{gall_029_candidate_digest: digest}
      |> Map.merge(
        if Keyword.get(opts, :idempotent, true),
          do: %{idempotency_key: "gall-030-#{key}"},
          else: %{}
      )

    command =
      Command.new(capability,
        command_id: Keyword.get(opts, :command_id, "gall-030-#{key}"),
        agent_id: "gall-030",
        principal_id: principal,
        authority: authority,
        input: input,
        metadata: metadata
      )

    message = data_message(%{"key" => key, "value" => "X"})

    postcondition = %Postcondition{
      id: "gall-030.ledger-value-persisted",
      verifier: LedgerVerifier,
      expect: %{key: key, value: "X"}
    }

    {command, message,
     [
       store_opts: store_opts,
       postcondition: Keyword.get(opts, :postcondition, postcondition),
       scope: %{input_digest: ProcessIntervention.canonical_digest(input)},
       max_consequences: 1,
       expected_postcondition: %{key: key, value: "X"}
     ]}
  end

  defp refused_before_do(command, key, store_opts) do
    assert Fixtures.stored_values(key) == []
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    refute_received {:actuate_start, _}
  end

  test "GALL-029 admits an exactly bound authority-free candidate" do
    source = finding()
    candidate = admit!(source)

    assert candidate.authority == :none
    assert candidate.evidence_ceiling == "ADMIT_ONLY"
    assert candidate.producer_repository == source.producer_repository
    assert candidate.producer_sha == source.producer_sha
    assert candidate.evidence_digest == source.evidence_digest
    assert candidate.semantic_subject_digest == source.semantic_subject_digest
    assert candidate.finding_class == source.finding_class
    assert candidate.finding_type == source.finding_type
    assert candidate.candidate_class == source.candidate_class
    assert candidate.horizon == source.horizon
    assert candidate.vocabulary == source.vocabulary
    assert candidate.capability_id == source.requested_capability_id
    assert String.starts_with?(candidate.finding_digest, "sha256:")
    assert String.starts_with?(candidate.candidate_digest, "sha256:")
  end

  test "prediction remains prediction-class evidence and secrets fail closed" do
    source = finding(%{finding_class: "prediction"})
    candidate = admit!(source)

    assert candidate.finding_class == "prediction"
    assert candidate.authority == :none

    assert {:error, :secret_bearing_finding} =
             ProcessIntervention.admit(
               Map.put(source, :authorization, "Bearer abc"),
               admission_opts(source)
             )
  end

  test "missing policy and stale or private identities fail closed" do
    source = finding()

    assert {:error, :producer_allowlist_required} = ProcessIntervention.admit(source)

    cases = [
      {:producer_sha, String.duplicate("d", 40), :stale_or_unadmitted_producer},
      {:evidence_digest, "sha256:" <> String.duplicate("d", 64), :stale_or_unadmitted_evidence},
      {:semantic_subject_digest, "sha256:" <> String.duplicate("d", 64),
       :stale_or_mismatched_semantic_subject},
      {:horizon, "SLOW", :unadmitted_horizon},
      {:requested_capability_id, Fixtures.capability(:lying_write), :capability_mismatch},
      {:vocabulary, "https://example.org/private", :private_or_unknown_vocabulary}
    ]

    for {field, value, expected} <- cases do
      mutated = Map.put(source, field, value)
      assert {:error, ^expected} = ProcessIntervention.admit(mutated, admission_opts(source))
    end

    assert {:error, :unadmitted_capability} =
             ProcessIntervention.admit(
               source,
               admission_opts(source,
                 allowed_capabilities: [Fixtures.capability(:lying_write)]
               )
             )
  end

  test "GALL-029 capability comes only from explicit semantic admission rule" do
    rule_capability = Fixtures.capability(:honest_write)
    source = Map.delete(finding(), :requested_capability_id)
    opts = admission_opts(source)

    assert {:ok, candidate} = ProcessIntervention.admit(source, opts)
    assert candidate.capability_id == rule_capability
    assert candidate.authority == :none
    assert candidate.evidence_ceiling == "ADMIT_ONLY"

    attacker =
      Map.put(source, :requested_capability_id, "attacker-supplied-value-is-not-authority")

    assert {:error, :capability_mismatch} = ProcessIntervention.admit(attacker, opts)

    assert {:error, :unsupported_process_finding_rule} =
             ProcessIntervention.admit(source, Keyword.put(opts, :admission_rules, %{}))

    assert {:error, :invalid_process_finding_rule} =
             ProcessIntervention.admit(
               source,
               Keyword.put(opts, :admission_rules, %{rule_key(source) => ""})
             )

    assert {:error, :invalid_process_finding_rules} =
             ProcessIntervention.admit(source, Keyword.delete(opts, :admission_rules))

    assert {:error, :unsupported_process_finding_rule} =
             ProcessIntervention.admit(
               Map.put(source, :finding_type, "unmodelled_type"),
               opts
             )
  end

  test "hex SHA/digest, repository shape and repository-pinned producers fail closed" do
    source = finding()
    opts = admission_opts(source)

    assert {:error, :producer_sha} =
             ProcessIntervention.admit(
               Map.put(source, :producer_sha, String.duplicate("z", 40)),
               opts
             )

    assert {:error, :evidence_digest} =
             ProcessIntervention.admit(
               Map.put(source, :evidence_digest, "sha256:" <> String.duplicate("z", 64)),
               opts
             )

    assert {:error, :semantic_subject_digest} =
             ProcessIntervention.admit(
               Map.put(source, :semantic_subject_digest, "sha256:" <> String.duplicate("Z", 64)),
               opts
             )

    assert {:error, :producer_repository} =
             ProcessIntervention.admit(Map.put(source, :producer_repository, "no-slash"), opts)

    assert {:error, :producer_repository} =
             ProcessIntervention.admit(Map.delete(source, :producer_repository), opts)

    pinned = %{source.producer_repository => source.producer_sha}

    assert {:ok, candidate} =
             ProcessIntervention.admit(source, Keyword.put(opts, :allowed_producers, pinned))

    assert candidate.producer_repository == source.producer_repository

    assert {:error, :stale_or_unadmitted_producer} =
             ProcessIntervention.admit(
               source,
               Keyword.put(opts, :allowed_producers, %{"other/repo" => source.producer_sha})
             )

    assert {:error, :producer_allowlist_required} =
             ProcessIntervention.admit(source, Keyword.put(opts, :allowed_producers, %{}))
  end

  test "candidate digest is semantic command identity for replay" do
    first = admit!(finding())
    second_source = finding(%{evidence_digest: "sha256:" <> String.duplicate("d", 64)})
    second = admit!(second_source)

    common = [
      command_id: "candidate-fingerprint",
      agent_id: "gall-030",
      principal_id: "gall-030",
      input: %{key: "k", value: "X"}
    ]

    first_command =
      Command.new(
        first.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: first.candidate_digest}]
      )

    second_command =
      Command.new(
        second.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: second.candidate_digest}]
      )

    refute first.candidate_digest == second.candidate_digest
    refute first_command.fingerprint == second_command.fingerprint
  end

  test "candidate without ADMIT_ONLY evidence ceiling is not an admitted candidate",
       %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-ceiling-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    forged =
      candidate
      |> Map.delete(:evidence_ceiling)
      |> Map.delete(:candidate_digest)
      |> then(&Map.put(&1, :candidate_digest, ProcessIntervention.canonical_digest(&1)))

    assert {:error, :gall_029_admission_required} =
             ProcessIntervention.intervene(forged, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "missing authority refuses before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-authority-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts, authorized: false)

    assert {:error, :authority_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "authority for another principal refuses before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "wrong-authority-#{System.unique_integer([:positive])}"

    other =
      Authority.new(Identity.principal("someone-else"), candidate.capability_id,
        token_id: "auth-other-#{key}"
      )

    {command, message, opts} = intervention(candidate, key, store_opts, authority: other)

    assert {:error, :authority_mismatch} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "one-DO policy budget refuses every unbounded shape before DO",
       %{store_opts: store_opts} do
    candidate = admit!(finding())

    cases = [
      {:intervention_scope_required, fn opts, _c -> Keyword.delete(opts, :scope) end},
      {:intervention_scope_required, fn opts, _c -> Keyword.put(opts, :scope, %{}) end},
      {:intervention_budget_must_be_one,
       fn opts, _c -> Keyword.put(opts, :max_consequences, 2) end},
      {:intervention_budget_must_be_one,
       fn opts, _c -> Keyword.delete(opts, :max_consequences) end},
      {:intervention_scope_input_mismatch,
       fn opts, _c ->
         Keyword.put(opts, :scope, %{
           input_digest: ProcessIntervention.canonical_digest(%{key: "other", value: "X"})
         })
       end},
      {:expected_postcondition_required,
       fn opts, _c -> Keyword.delete(opts, :expected_postcondition) end},
      {:observer_postcondition_subject_mismatch,
       fn opts, _c -> Keyword.put(opts, :expected_postcondition, %{key: "other", value: "Y"}) end}
    ]

    for {expected, mutate} <- cases do
      key = "budget-#{expected}-#{System.unique_integer([:positive])}"
      {command, message, opts} = intervention(candidate, key, store_opts)

      assert {:error, ^expected} =
               ProcessIntervention.intervene(
                 candidate,
                 command,
                 message,
                 Ledger,
                 mutate.(opts, command)
               )

      refused_before_do(command, key, store_opts)
    end

    key = "no-idempotency-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts, idempotent: false)

    assert {:error, :intervention_idempotency_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "candidate metadata mismatch refuses before CommandBus DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "bad-binding-#{System.unique_integer([:positive])}"

    {command, message, opts} =
      intervention(candidate, key, store_opts,
        candidate_digest: "sha256:" <> String.duplicate("0", 64)
      )

    assert {:error, :candidate_binding_mismatch} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "independent observer is mandatory before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-observer-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)
    opts = Keyword.delete(opts, :postcondition)

    assert {:error, :independent_observer_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    refused_before_do(command, key, store_opts)
  end

  test "authorized intervention crosses DO once through CommandBus and independently verifies post-state",
       %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "alive-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    assert {:ok, %{command_receipt: receipt, observer_receipt: observer} = result} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert result.evidence_ceiling == "AUTHORIZED_DO"
    assert result.postcondition_standing == "VERIFIED"

    assert result.expected_postcondition_digest ==
             ProcessIntervention.canonical_digest(%{key: key, value: "X"})

    assert receipt.status == :completed
    assert receipt.fingerprint == command.fingerprint
    assert observer.status == :verified
    assert observer.independent == true
    assert Fixtures.stored_values(key) == ["X"]

    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
    assert stored.fingerprint == command.fingerprint

    assert_received {:actuate_start, %{command_id: _}}
    refute_received {:actuate_start, _}
  end

  test "GALL-030 exact scoped replay stays one effect", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "replay-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    assert {:ok, first} = ProcessIntervention.intervene(candidate, command, message, Ledger, opts)
    assert first.evidence_ceiling == "AUTHORIZED_DO"
    assert Fixtures.stored_values(key) == ["X"]
    assert_received {:actuate_start, _}

    replay = ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert {:ok, replayed} = replay
    assert replayed.command_receipt.replayed? == true
    assert replayed.command_receipt.receipt_id == first.command_receipt.receipt_id
    assert replayed.postcondition_standing == "VERIFIED"

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}

    assert {:error, :intervention_budget_must_be_one} =
             ProcessIntervention.intervene(
               candidate,
               command,
               message,
               Ledger,
               Keyword.put(opts, :max_consequences, 2)
             )

    # A replay whose declared observer names a different postcondition id
    # (same expectation) must not inherit the stored observation as its own.
    renamed = %Postcondition{
      id: "gall-030.some-other-postcondition",
      verifier: LedgerVerifier,
      expect: %{key: key, value: "X"}
    }

    assert {:error, :observer_postcondition_subject_mismatch} =
             ProcessIntervention.intervene(
               candidate,
               command,
               message,
               Ledger,
               Keyword.put(opts, :postcondition, renamed)
             )

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}
  end

  test "candidate swap on the same command id conflicts and cannot replay another finding's receipt",
       %{store_opts: store_opts} do
    first = admit!(finding())
    second_source = finding(%{evidence_digest: "sha256:" <> String.duplicate("d", 64)})
    second = admit!(second_source)
    key = "candidate-swap-#{System.unique_integer([:positive])}"
    command_id = "gall-030-swap-#{System.unique_integer([:positive])}"

    {first_command, first_message, first_opts} =
      intervention(first, key, store_opts, command_id: command_id)

    {second_command, second_message, second_opts} =
      intervention(second, key, store_opts, command_id: command_id)

    assert {:ok, %{command_receipt: first_receipt}} =
             ProcessIntervention.intervene(
               first,
               first_command,
               first_message,
               Ledger,
               first_opts
             )

    assert first_receipt.status == :completed
    assert_received {:actuate_start, _}

    assert {:error, %{code: :command_conflict}} =
             ProcessIntervention.intervene(
               second,
               second_command,
               second_message,
               Ledger,
               second_opts
             )

    assert Fixtures.stored_values(key) == ["X"]
    refute_received {:actuate_start, _}
  end
end
