defmodule AshA2A.Gall.ProcessInterventionTest do
  use ExUnit.Case, async: false

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
        producer_sha: String.duplicate("a", 40),
        evidence_digest: "sha256:" <> String.duplicate("b", 64),
        semantic_subject_digest: "sha256:" <> String.duplicate("c", 64),
        finding_class: "conformance",
        horizon: "FAST",
        vocabulary: "https://w3id.org/ocel",
        requested_capability_id: Fixtures.capability(:honest_write)
      },
      overrides
    )
  end

  defp admission_opts(finding, overrides \\ []) do
    [
      allowed_producers: [finding.producer_sha],
      allowed_evidence_digests: [finding.evidence_digest],
      allowed_semantic_subjects: [finding.semantic_subject_digest],
      allowed_horizons: [finding.horizon],
      allowed_capabilities: [finding.requested_capability_id],
      public_vocabulary: [finding.vocabulary]
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
        Authority.new(principal, capability, token_id: "auth-#{key}")
      end

    digest = Keyword.get(opts, :candidate_digest, candidate.candidate_digest)

    command =
      Command.new(capability,
        command_id: Keyword.get(opts, :command_id, "gall-030-#{key}"),
        agent_id: "gall-030",
        principal_id: principal,
        authority: authority,
        input: %{key: key, value: "X"},
        metadata: %{gall_029_candidate_digest: digest}
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
       postcondition: Keyword.get(opts, :postcondition, postcondition)
     ]}
  end

  test "GALL-029 admits an exactly bound authority-free candidate" do
    source = finding()
    candidate = admit!(source)

    assert candidate.authority == :none
    assert candidate.producer_sha == source.producer_sha
    assert candidate.evidence_digest == source.evidence_digest
    assert candidate.semantic_subject_digest == source.semantic_subject_digest
    assert candidate.finding_class == source.finding_class
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
      {:requested_capability_id, Fixtures.capability(:lying_write), :unadmitted_capability},
      {:vocabulary, "https://example.org/private", :private_or_unknown_vocabulary}
    ]

    for {field, value, expected} <- cases do
      mutated = Map.put(source, field, value)
      assert {:error, ^expected} = ProcessIntervention.admit(mutated, admission_opts(source))
    end
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
      Command.new(first.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: first.candidate_digest}]
      )

    second_command =
      Command.new(second.capability_id,
        common ++ [metadata: %{gall_029_candidate_digest: second.candidate_digest}]
      )

    refute first.candidate_digest == second.candidate_digest
    refute first_command.fingerprint == second_command.fingerprint
  end

  test "missing authority refuses before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-authority-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts, authorized: false)

    assert {:error, %{code: :authority_required}} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert Fixtures.stored_values(key) == []
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    refute_received {:actuate_start, _}
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

    assert Fixtures.stored_values(key) == []
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    refute_received {:actuate_start, _}
  end

  test "independent observer is mandatory before DO", %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "no-observer-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)
    opts = Keyword.delete(opts, :postcondition)

    assert {:error, :independent_observer_required} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

    assert Fixtures.stored_values(key) == []
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    refute_received {:actuate_start, _}
  end

  test "authorized intervention crosses DO once through CommandBus and independently verifies post-state",
       %{store_opts: store_opts} do
    candidate = admit!(finding())
    key = "alive-#{System.unique_integer([:positive])}"
    {command, message, opts} = intervention(candidate, key, store_opts)

    assert {:ok, %{command_receipt: receipt, observer_receipt: observer}} =
             ProcessIntervention.intervene(candidate, command, message, Ledger, opts)

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
