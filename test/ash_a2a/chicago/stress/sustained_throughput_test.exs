defmodule AshA2A.Chicago.Stress.SustainedThroughputTest do
  @moduledoc """
  RFC-SA2A-002 stress/soak coverage: real, sustained `AshA2A.CommandBus.run/4`
  dispatch under real concurrent load for a bounded real wall-clock duration.

  This is not a micro-benchmark of one admission stage (that is
  `AshA2A.Chicago.Bench.B1Admission`/`B5Authority`/`B9OcelOverhead`, driven
  once per RFC-named case). It drives the FULL real consequence path --
  `CommandBus.run/4` -> admission -> claim -> actuation claim -> receipt
  anchor -> real `Ash.create` dispatch -> postcondition -> commit -- against
  a real, shared `AshA2A.ReceiptStore.Memory` `GenServer` and a real
  `Ash.DataLayer.Ets`-backed `AshA2A.Test.Fixture.Item` resource, for
  hundreds to low thousands of genuinely distinct commands over a real
  10-30s window, from `N = System.schedulers_online()` real concurrent BEAM
  processes running continuously for that whole window (not N fixed
  upfront tasks -- each worker keeps issuing new, unique commands until the
  real deadline passes).

  ## Real collaborators, no mocking (this workspace's Chicago-style
  discipline)

  Every command is a real `AshA2A.Command`, dispatched through the real
  `AshA2A.CommandBus.run/4` public API used by production callers (the same
  entry point `test/ash_a2a/command_bus_test.exs` and
  `test/ash_a2a_command_bus_concurrency_test.exs` already exercise directly);
  authority is a real `AshA2A.Authority` struct built with
  `AshA2A.Authority.new/3` and attached to the command (the same pattern
  those two files use -- `CommandBus.run/4`'s `admit/2` reads
  `command.authority` directly; it does not consult the standing
  `AshA2A.Authority.Broker` at this layer, that fail-closed broker lookup
  happens one layer up in `AshA2A.Agent.build_command/4`). Every command_id
  and every `Item.label` is genuinely distinct
  (`System.unique_integer([:positive, :monotonic])`-suffixed), so no
  deliberate collision is being raced here (that is
  `ash_a2a_command_bus_concurrency_test.exs`'s job) -- this file's job is
  sustained throughput/latency/error-rate/resource-drift under real
  continuous load, not claim-arbitration correctness.

  ## Measurement, reused from the real Chicago bench harness

  Latency distribution (`min`/`p50`/`p90`/`p95`/`p99`/`max`/`mean`/`stddev`)
  and throughput are computed with the SAME real
  `AshA2A.Chicago.Bench.distribution/1` and `AshA2A.Chicago.Bench.per_second/2`
  this repo's B1/B5/B9 benchmarks use -- not a second, parallel stats
  implementation. Samples are also bucketed by real wall-clock offset into
  the run's first half vs. second half so a genuine degradation-under-
  sustained-load pattern (climbing latency, not just steady noise) can be
  reported from real numbers rather than inferred from a single aggregate.
  `:erlang.memory/0` and `:erlang.system_info(:process_count)` are sampled
  before and after the full run to surface a real gross resource-growth
  signal (not a precise per-object leak proof -- stated as such wherever
  reported).

  ## Running this file

  Excluded from the default suite (`test/test_helper.exs` excludes
  `:benchmark`, the same convention
  `test/ash_a2a/planning/goal_facts_density_benchmark_test.exs` already
  uses) because it deliberately runs for a real 10-30s wall-clock window.
  Run it explicitly:

      mix test test/ash_a2a/chicago/stress/sustained_throughput_test.exs --include benchmark

  Override the real run duration with `ASH_A2A_STRESS_DURATION_MS` (default
  `#{12_000}`); override worker concurrency with `ASH_A2A_STRESS_WORKERS`
  (default `System.schedulers_online()`).
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Bench, Json}
  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.Item

  import AshA2A.Test.MessageHelpers

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @capability "AshA2A.Test.Fixture.Item.create"
  @default_duration_ms 12_000
  @min_expected_samples 100

  test "sustained CommandBus.run/4 throughput/latency/error-rate over a real bounded window" do
    duration_ms = duration_ms()
    workers = worker_count()
    run_id = System.unique_integer([:positive])
    label_prefix = "stress-#{run_id}-"

    store_name = Module.concat(__MODULE__, "Store#{run_id}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store_name})
    store_opts = [name: store_name]

    # One real warm-up create (mirrors `ash_a2a_command_bus_concurrency_test
    # .exs`'s documented `Ash.DataLayer.Ets.TableManager` race: the table's
    # manager can be racing its own first write on a fresh VM run; one real
    # serialized create before the timed window makes the table exist so the
    # timed window measures real dispatch cost, not a one-time table-init
    # cost attributed to whichever worker happens to go first).
    {:ok, _warmup} =
      Item
      |> Ash.Changeset.for_create(:create, %{label: "#{label_prefix}warmup"})
      |> Ash.create(domain: AshA2A.Test.Fixture.ItemDomain)

    memory_before = Map.new(:erlang.memory())
    processes_before = :erlang.system_info(:process_count)

    run_started_ms = System.monotonic_time(:millisecond)
    deadline_ms = run_started_ms + duration_ms

    results =
      1..workers
      |> Task.async_stream(
        fn worker_idx ->
          drive_worker(worker_idx, run_id, label_prefix, deadline_ms, run_started_ms, %{
            capability: @capability,
            store_opts: store_opts
          })
        end,
        max_concurrency: workers,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, samples} -> samples end)

    wall_ms = System.monotonic_time(:millisecond) - run_started_ms

    memory_after = Map.new(:erlang.memory())
    processes_after = :erlang.system_info(:process_count)

    sample_count = length(results)
    {ok_samples, error_samples} = Enum.split_with(results, &(&1.outcome == :ok))

    durations_us = Enum.map(ok_samples, & &1.duration_us)
    latency = Bench.distribution(durations_us)
    throughput = Bench.per_second(sample_count, max(wall_ms * 1_000, 1))
    error_rate = if sample_count > 0, do: length(error_samples) / sample_count, else: 0.0

    # Real time-bucketed degradation check: first half of the window vs.
    # second half, by each sample's REAL start offset from `run_started_ms`
    # (not by list order -- workers interleave).
    half_ms = duration_ms / 2

    {early, late} =
      Enum.split_with(ok_samples, fn s -> s.start_offset_ms < half_ms end)

    early_latency = Bench.distribution(Enum.map(early, & &1.duration_us))
    late_latency = Bench.distribution(Enum.map(late, & &1.duration_us))

    degradation_ratio_p50 =
      ratio(Map.get(late_latency, "p50"), Map.get(early_latency, "p50"))

    degradation_ratio_p99 =
      ratio(Map.get(late_latency, "p99"), Map.get(early_latency, "p99"))

    report = %{
      "run_id" => run_id,
      "workers" => workers,
      "requested_duration_ms" => duration_ms,
      "actual_wall_ms" => wall_ms,
      "sample_count" => sample_count,
      "ok_count" => length(ok_samples),
      "error_count" => length(error_samples),
      "error_rate" => Float.round(error_rate, 4),
      "throughput_per_second" => throughput,
      "latency_us" => latency,
      "early_half_latency_us" => early_latency,
      "late_half_latency_us" => late_latency,
      "degradation_ratio_p50" => degradation_ratio_p50,
      "degradation_ratio_p99" => degradation_ratio_p99,
      "memory_before_bytes" => stringify(memory_before),
      "memory_after_bytes" => stringify(memory_after),
      "memory_delta_bytes" => delta(memory_before, memory_after),
      "processes_before" => processes_before,
      "processes_after" => processes_after,
      "process_delta" => processes_after - processes_before
    }

    IO.puts("\n[SA2A-STRESS-SUSTAINED] " <> Json.canonical(report))

    # --- real, state-based invariants -------------------------------------

    # Enough real load was actually generated to call this a sustained-
    # throughput run, not a handful of samples (floor kept low enough to
    # hold on a slow/loaded CI host; the real observed number is what gets
    # reported, this only guards against a run that silently did ~nothing).
    assert sample_count >= @min_expected_samples,
           "expected at least #{@min_expected_samples} real dispatches in #{duration_ms}ms, " <>
             "got #{sample_count} -- real sustained load did not materialize"

    # Every command_id was genuinely distinct and every dispatch that
    # returned :ok completed for real (not replayed -- replay would mean a
    # command_id collision, which this file's id-generation must never
    # produce).
    assert Enum.all?(ok_samples, & &1.completed?)
    refute Enum.any?(ok_samples, & &1.replayed?)

    receipt_ids = Enum.map(ok_samples, & &1.receipt_id)
    assert length(Enum.uniq(receipt_ids)) == length(receipt_ids)

    # Zero errors is the real expected invariant for this design: every
    # command carries a matching, non-model authority and a globally unique
    # command_id/label, so no legitimate admission/claim/actuation refusal
    # exists to trigger. A real error surfacing here is a real defect (in
    # this test's own id-uniqueness, or in the SUT) to be named, not
    # papered over.
    assert error_samples == [],
           "expected zero errors under sustained load, got: " <>
             inspect(Enum.take(error_samples, 5))

    # Real data-layer proof, independent of the receipts returned: exactly
    # `sample_count` real `Item` rows carry this run's unique label prefix
    # (the concurrency suite's real-collaborator-safe counting pattern,
    # since the ETS table is not reset between test files in the suite).
    assert {:ok, all_items} = Ash.read(Item, domain: AshA2A.Test.Fixture.ItemDomain)
    real_rows = Enum.count(all_items, &String.starts_with?(&1.label, label_prefix))
    assert real_rows == sample_count + 1, "+1 for the real warm-up row created above"
  end

  defp drive_worker(worker_idx, run_id, label_prefix, deadline_ms, run_started_ms, ctx) do
    principal = Identity.principal("stress-worker-#{run_id}-#{worker_idx}")

    authority =
      Authority.new(principal, ctx.capability, token_id: "stress-auth-#{run_id}-#{worker_idx}")

    drive_worker_loop(
      worker_idx,
      run_id,
      label_prefix,
      deadline_ms,
      run_started_ms,
      ctx,
      principal,
      authority,
      []
    )
  end

  defp drive_worker_loop(
         worker_idx,
         run_id,
         label_prefix,
         deadline_ms,
         run_started_ms,
         ctx,
         principal,
         authority,
         acc
       ) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      Enum.reverse(acc)
    else
      seq = System.unique_integer([:positive, :monotonic])
      label = "#{label_prefix}#{worker_idx}-#{seq}"

      command =
        Command.new(ctx.capability,
          command_id: "#{label_prefix}cmd-#{worker_idx}-#{seq}",
          agent_id: "stress-agent-#{worker_idx}",
          principal_id: principal,
          authority: authority,
          input: %{label: label}
        )

      message = data_message(%{"label" => label})

      start_offset_ms = System.monotonic_time(:millisecond) - run_started_ms
      started_us = System.monotonic_time(:microsecond)
      reply = CommandBus.run(command, message, Item, store_opts: ctx.store_opts)
      duration_us = System.monotonic_time(:microsecond) - started_us

      sample =
        case reply do
          {:ok, receipt} ->
            %{
              outcome: :ok,
              duration_us: duration_us,
              start_offset_ms: start_offset_ms,
              receipt_id: receipt.receipt_id,
              completed?: receipt.status == :completed,
              replayed?: receipt.replayed?
            }

          {:error, reason} ->
            %{
              outcome: :error,
              duration_us: duration_us,
              start_offset_ms: start_offset_ms,
              reason: reason
            }
        end

      drive_worker_loop(
        worker_idx,
        run_id,
        label_prefix,
        deadline_ms,
        run_started_ms,
        ctx,
        principal,
        authority,
        [sample | acc]
      )
    end
  end

  defp duration_ms do
    case System.get_env("ASH_A2A_STRESS_DURATION_MS") do
      nil -> @default_duration_ms
      raw -> String.to_integer(raw)
    end
  end

  defp worker_count do
    case System.get_env("ASH_A2A_STRESS_WORKERS") do
      nil -> max(System.schedulers_online(), 2)
      raw -> String.to_integer(raw)
    end
  end

  defp ratio(_late, nil), do: nil
  defp ratio(nil, _early), do: nil
  defp ratio(_late, 0), do: nil

  defp ratio(late, early) when is_number(late) and is_number(early),
    do: Float.round(late / early, 3)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp delta(before_map, after_map) do
    Map.new(after_map, fn {k, v} -> {Atom.to_string(k), v - Map.get(before_map, k, 0)} end)
  end
end
