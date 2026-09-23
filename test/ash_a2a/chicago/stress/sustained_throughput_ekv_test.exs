defmodule AshA2A.Chicago.Stress.SustainedThroughputEkvTest do
  @moduledoc """
  RFC-SA2A-002 stress/soak coverage: the exact same real, sustained
  `AshA2A.CommandBus.run/4` dispatch this suite's own
  `sustained_throughput_test.exs` drives against a real, shared
  `AshA2A.ReceiptStore.Memory` `GenServer` -- except this file drives it
  against a real, on-disk `AshA2A.ReceiptStore.Ekv` instance instead, via
  `opts: [store: AshA2A.ReceiptStore.Ekv, store_opts: [name: <unique EKV
  instance>]]`.

  This is the direct comparative counterpart the sibling file's own
  moduledoc calls for: `CommandBus.run/4`'s `admit/2` reads
  `command.authority` directly (the sibling's moduledoc explains why
  `AshA2A.Authority.Broker` is not implicated in this specific number), and
  the ONLY real variable changed between the two files is which
  `AshA2A.ReceiptStore` backend every concurrent claim/commit funnels
  through -- `Memory`'s single-GenServer-mailbox serialization point versus
  `Ekv`'s per-key CAS (`if_vsn:`) with zero cross-command_id contention (see
  `AshA2A.ReceiptStore.Ekv`'s own moduledoc: "Unlike Memory ... this module
  has no such free serialization" -- meaning no shared mailbox to serialize
  through, not that concurrent claims are unsafe; per-key CAS is the real
  concurrency-safety mechanism here). Real command volume, duration, worker
  count, `AshA2A.Chicago.Bench.distribution/1` / `per_second/2` measurement,
  and first-half-vs-second-half bucketing are byte-for-byte identical to the
  sibling file so the two reports are a real, apples-to-apples comparison,
  not two differently-shaped runs.

  ## Real EKV setup, mirrored from this repo's own established pattern

  `start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size:
  1})` against a real temp `data_dir` under `System.tmp_dir!/0` -- the exact
  real-local-EKV pattern `test/ash_a2a/receipt_store_ekv_test.exs` and
  `test/ash_a2a_runtime_providers_integration_test.exs` already use. No
  mock/stub of `EKV` or of the `AshA2A.ReceiptStore` behaviour anywhere in
  this file (this workspace's Chicago-style discipline, same as the
  sibling).

  ## Running this file

  Excluded from the default suite (`:benchmark` tag, same convention as the
  sibling). Run it explicitly:

      mix test test/ash_a2a/chicago/stress/sustained_throughput_ekv_test.exs --include benchmark

  Override the real run duration with `ASH_A2A_STRESS_DURATION_MS` (default
  `#{12_000}`); override worker concurrency with `ASH_A2A_STRESS_WORKERS`
  (default `System.schedulers_online()`) -- same env vars, same defaults as
  the sibling file, so a side-by-side run uses identical load shape unless
  explicitly overridden the same way for both.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Chicago.{Bench, Json}
  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.ReceiptStore.Ekv
  alias AshA2A.Test.Fixture.Item

  import AshA2A.Test.MessageHelpers

  @moduletag :benchmark
  # No `:serial`/`:serial_shard`/`:serial_solo` tag here (removed, ASH_A2A-26922-02):
  # `mix test.all` = `test --include serial`, and ExUnit's include filter
  # rescues ANY test matching the include from ALL exclusions -- a serial
  # tag on this whole-module `:benchmark` file re-admitted the benchmark
  # into the CI lane. With no serial tag, the `:benchmark` exclusion in
  # test_helper.exs is un-overridable by `--include serial`; run this file
  # explicitly (`mix test <path>` or `--only benchmark`).
  @moduletag timeout: :infinity

  @capability "AshA2A.Test.Fixture.Item.create"
  @default_duration_ms 12_000
  @min_expected_samples 100

  test "sustained CommandBus.run/4 throughput/latency/error-rate over a real bounded window, Ekv-backed" do
    duration_ms = duration_ms()
    workers = worker_count()
    run_id = System.unique_integer([:positive])
    label_prefix = "stress-ekv-#{run_id}-"

    ekv_name = :"ash_a2a_stress_ekv_#{run_id}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_stress_ekv_#{run_id}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)

    # cluster_size: 1 -- a real single-voter setup, sufficient for this
    # bounded real load window; mirrors
    # test/ash_a2a/receipt_store_ekv_test.exs's real local EKV setup
    # exactly.
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

    store_opts = [name: ekv_name]

    # One real warm-up create, same reason as the sibling Memory-backed
    # file: makes the real `Ash.DataLayer.Ets.TableManager` table exist
    # before the timed window, and (for this store) also exercises one real
    # EKV claim/commit round-trip before timing so the fresh-instance/
    # fresh-CAS-table path is not what the first timed sample measures.
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
    # (not by list order -- workers interleave). Identical bucketing logic
    # to the sibling Memory-backed file.
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
      "store" => "Ekv",
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

    IO.puts("\n[SA2A-STRESS-SUSTAINED-EKV] " <> Json.canonical(report))

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

    # Real proof this run actually went through Ekv, not a Memory fallback:
    # every committed receipt is durably fetchable straight from the real
    # on-disk store by command_id, independent of the in-process receipt
    # values already asserted above.
    sample_ids = ok_samples |> Enum.take(5) |> Enum.map(& &1.command_id)

    for command_id <- sample_ids do
      assert {:ok, _receipt} = Ekv.fetch(Identity.command(command_id), name: ekv_name)
    end
  end

  defp drive_worker(worker_idx, run_id, label_prefix, deadline_ms, run_started_ms, ctx) do
    principal = Identity.principal("stress-ekv-worker-#{run_id}-#{worker_idx}")

    authority =
      Authority.new(principal, ctx.capability,
        token_id: "stress-ekv-auth-#{run_id}-#{worker_idx}"
      )

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
      command_id = "#{label_prefix}cmd-#{worker_idx}-#{seq}"

      command =
        Command.new(ctx.capability,
          command_id: command_id,
          agent_id: "stress-ekv-agent-#{worker_idx}",
          principal_id: principal,
          authority: authority,
          input: %{label: label}
        )

      message = data_message(%{"label" => label})

      start_offset_ms = System.monotonic_time(:millisecond) - run_started_ms
      started_us = System.monotonic_time(:microsecond)

      reply =
        CommandBus.run(command, message, Item,
          store: AshA2A.ReceiptStore.Ekv,
          store_opts: ctx.store_opts
        )

      duration_us = System.monotonic_time(:microsecond) - started_us

      sample =
        case reply do
          {:ok, receipt} ->
            %{
              outcome: :ok,
              duration_us: duration_us,
              start_offset_ms: start_offset_ms,
              command_id: command_id,
              receipt_id: receipt.receipt_id,
              completed?: receipt.status == :completed,
              replayed?: receipt.replayed?
            }

          {:error, reason} ->
            %{
              outcome: :error,
              duration_us: duration_us,
              start_offset_ms: start_offset_ms,
              command_id: command_id,
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
