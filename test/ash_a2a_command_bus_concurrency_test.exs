defmodule AshA2ACommandBusConcurrencyTest do
  @moduledoc """
  Squad H (replay/concurrency stress, agent 38) -- real BEAM concurrency
  coverage for `AshA2A.CommandBus.run/4` racing `AshA2A.ReceiptStore.Memory`.

  `AshA2A.ReceiptStore.Memory` is a real `GenServer`; its real serialized
  `handle_call({:claim, command}, ...)` is the only thing standing between
  N concurrent callers and N real duplicate `Ash.create` executions. This
  file does not assume that mutual exclusion holds from reading the source --
  it spawns real concurrent Elixir processes (`Task.async_stream/3`, real
  BEAM scheduler concurrency, `max_concurrency` pinned to the full fan-out so
  every caller is genuinely in flight at once, not batched into scheduler-
  sized chunks) and proves it against the real `AshA2A.Test.Fixture.Item`
  Ash resource (`Ash.DataLayer.Ets`, a real data layer, not a fake).

  ## A real finding this file's assertions are built around

  `AshA2A.ReceiptStore.Memory.handle_call/3`'s `{:claim, command}` clause has
  three live outcomes for a matching fingerprint, not two:

    - `entry.receipt == nil`             -> `{:error, :in_flight}`
    - `entry.receipt == %Receipt{}`      -> `{:replay, receipt}`
    - no entry yet                       -> `{:execute, execution_id}`

  A genuinely concurrent racer that reaches the GenServer's mailbox *before*
  the executing caller's real `Ash.create` dispatch finishes and calls
  `commit/2` lands in the first bucket (`:in_flight`), not the second
  (`:replay`) -- `Ash.create`'s real changeset/validation/data-layer pipeline
  takes real, non-zero wall-clock time, so under true simultaneous load most
  or all racers are observed here to land `:in_flight`, with `:replay` shown
  for real by a caller that arrives strictly after the race has settled. The
  literal invariant this file proves for the genuinely concurrent case is
  therefore the stronger, more general one that is actually true under real
  load: exactly one real execution, and every other concurrent caller gets
  either a faithful replay of that exact receipt or a clean, typed
  `:in_flight` refusal -- never a second execution, never a divergent
  receipt, never an untyped crash.

  No `Mox`/`:meck`/`Mock(`/`monkeypatch` anywhere in this file: real
  `Task.async_stream/3` processes, a real supervised `GenServer`, a real Ash
  resource and data layer throughout.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.Item

  @concurrency 30

  setup do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  # `AshA2A.Test.Fixture.Item` is backed by a single, process-global
  # `Ash.DataLayer.Ets` table that is NOT reset between tests -- every other
  # test file in the full suite that exercises `Item` (and this file's own
  # two tests, run in the same process) writes into the SAME table. A bare
  # "how many rows exist total" count would therefore silently pick up
  # unrelated rows left behind by earlier tests. Every assertion in this
  # file instead counts real rows matching a `label` unique to the specific
  # command under test (`System.unique_integer/1`-suffixed below), the same
  # real-collaborator-safe pattern `ash_a2a_agent_command_bus_test.exs`
  # already uses (`Enum.count(all_items, &(&1.id == created1.id))`) rather
  # than a raw table count.
  defp count_items_with_label(label) do
    assert {:ok, items} = Ash.read(Item, domain: AshA2A.Test.Fixture.ItemDomain)
    Enum.count(items, &(&1.label == label))
  end

  test "N real concurrent processes racing the identical command_id: exactly one real Ash create executes, never two",
       %{store_opts: store_opts} do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("racer-single-#{System.unique_integer([:positive])}")
    authority = Authority.new(principal, capability, token_id: "auth-race-single")
    label = "race-widget-#{System.unique_integer([:positive])}"

    # One real `Command` struct, shared by reference across every concurrent
    # task -- guarantees byte-identical semantic content (and therefore an
    # identical `fingerprint`) without reconstructing it per process, which
    # is the real thing "identical capability_id/agent_id/principal_id/
    # input/authority" means here.
    command =
      Command.new(capability,
        command_id: "race-single-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-single",
        principal_id: principal,
        authority: authority,
        input: %{label: label}
      )

    message = data_message(%{"label" => label})

    results =
      1..@concurrency
      |> Task.async_stream(
        fn _ -> CommandBus.run(command, message, Item, store_opts: store_opts) end,
        max_concurrency: @concurrency,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(results) == @concurrency

    executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
    replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
    refused = Enum.filter(results, &match?({:error, _}, &1))

    # The core invariant: not a race that lets two concurrent callers both
    # execute. Exactly one real `Ash.create` happened.
    assert length(executed) == 1
    [{:ok, executor_receipt}] = executed
    assert executor_receipt.status == :completed
    assert executor_receipt.consequence == :change
    refute executor_receipt.replayed?

    # Every caller that did NOT execute landed in one of exactly two clean,
    # accounted-for outcomes -- a faithful replay of the SAME receipt, or a
    # typed in-flight refusal -- never a divergent receipt and never any
    # other error code (in particular never `:command_conflict`, which would
    # mean the store mistook identical content for a fingerprint mismatch).
    for {:ok, replay_receipt} <- replayed do
      assert replay_receipt.replayed?
      assert replay_receipt.receipt_id == executor_receipt.receipt_id
      assert replay_receipt.fingerprint == executor_receipt.fingerprint
      assert replay_receipt.status == :completed
    end

    for {:error, reason} <- refused do
      assert reason.code == :in_flight
    end

    assert length(executed) + length(replayed) + length(refused) == @concurrency

    # Real data-layer proof, independent of the receipts returned: exactly
    # one real `Item` row with this test's unique label exists, not
    # `@concurrency` of them.
    assert count_items_with_label(label) == 1

    # Proves the replay path is real and not merely an artifact of timing:
    # a caller arriving strictly after the race has fully settled (all
    # `@concurrency` tasks awaited) must observe a real replay of the exact
    # same receipt, and must not create a second record.
    assert {:ok, post_race_receipt} =
             CommandBus.run(command, message, Item, store_opts: store_opts)

    assert post_race_receipt.replayed?
    assert post_race_receipt.receipt_id == executor_receipt.receipt_id
    assert count_items_with_label(label) == 1
  end

  test "two different command_ids racing concurrently execute independently with zero cross-contamination",
       %{store_opts: store_opts} do
    capability = "AshA2A.Test.Fixture.Item.create"
    principal = Identity.principal("racer-multi-#{System.unique_integer([:positive])}")

    authority_a = Authority.new(principal, capability, token_id: "auth-race-a")
    authority_b = Authority.new(principal, capability, token_id: "auth-race-b")
    label_a = "widget-a-#{System.unique_integer([:positive])}"
    label_b = "widget-b-#{System.unique_integer([:positive])}"

    command_a =
      Command.new(capability,
        command_id: "race-a-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-a",
        principal_id: principal,
        authority: authority_a,
        input: %{label: label_a}
      )

    command_b =
      Command.new(capability,
        command_id: "race-b-#{System.unique_integer([:positive])}",
        agent_id: "agent-race-b",
        principal_id: principal,
        authority: authority_b,
        input: %{label: label_b}
      )

    message_a = data_message(%{"label" => label_a})
    message_b = data_message(%{"label" => label_b})

    half = div(@concurrency, 2)

    # Interleave (shuffle) the two command's tasks so real scheduling does
    # not happen to group all of A's callers before all of B's -- both
    # command_ids are genuinely racing each other concurrently, not merely
    # running two separate serial batches back to back.
    tasks =
      (List.duplicate({:a, command_a, message_a}, half) ++
         List.duplicate({:b, command_b, message_b}, half))
      |> Enum.shuffle()

    results =
      tasks
      |> Task.async_stream(
        fn {tag, command, message} ->
          {tag, CommandBus.run(command, message, Item, store_opts: store_opts)}
        end,
        max_concurrency: length(tasks),
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    results_a = for {:a, result} <- results, do: result
    results_b = for {:b, result} <- results, do: result

    assert length(results_a) == half
    assert length(results_b) == half

    executor_a = assert_single_real_execution!(results_a)
    executor_b = assert_single_real_execution!(results_b)

    # No cross-contamination: the two command_ids produced two genuinely
    # distinct receipts/executions, correctly keyed to their own command.
    refute executor_a.receipt_id == executor_b.receipt_id
    assert executor_a.command_id == command_a.command_id
    assert executor_b.command_id == command_b.command_id

    for {:ok, receipt} <- results_a, receipt.replayed? do
      assert receipt.receipt_id == executor_a.receipt_id
      assert receipt.command_id == command_a.command_id
      refute receipt.receipt_id == executor_b.receipt_id
    end

    for {:ok, receipt} <- results_b, receipt.replayed? do
      assert receipt.receipt_id == executor_b.receipt_id
      assert receipt.command_id == command_b.command_id
      refute receipt.receipt_id == executor_a.receipt_id
    end

    # Two independent real records -- one per distinct command_id, each
    # identified by its own test-unique label -- proven against the real
    # Ets data layer, not inferred from receipts alone.
    assert count_items_with_label(label_a) == 1
    assert count_items_with_label(label_b) == 1

    assert {:ok, replay_a} = CommandBus.run(command_a, message_a, Item, store_opts: store_opts)
    assert replay_a.replayed?
    assert replay_a.receipt_id == executor_a.receipt_id

    assert {:ok, replay_b} = CommandBus.run(command_b, message_b, Item, store_opts: store_opts)
    assert replay_b.replayed?
    assert replay_b.receipt_id == executor_b.receipt_id

    assert count_items_with_label(label_a) == 1
    assert count_items_with_label(label_b) == 1
  end

  # Same per-command invariant as the single-command_id test above, reused
  # for each of the two racing command_ids: exactly one real execution,
  # every other real outcome a faithful replay or a clean `:in_flight`
  # refusal, nothing else. Returns the real executor receipt.
  defp assert_single_real_execution!(results) do
    executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
    replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
    refused = Enum.filter(results, &match?({:error, _}, &1))

    assert length(executed) == 1
    [{:ok, executor_receipt}] = executed
    assert executor_receipt.status == :completed
    assert executor_receipt.consequence == :change

    for {:ok, replay_receipt} <- replayed do
      assert replay_receipt.receipt_id == executor_receipt.receipt_id
    end

    for {:error, reason} <- refused do
      assert reason.code == :in_flight
    end

    assert length(executed) + length(replayed) + length(refused) == length(results)

    executor_receipt
  end
end
