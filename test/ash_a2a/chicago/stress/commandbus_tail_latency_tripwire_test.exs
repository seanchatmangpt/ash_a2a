# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Stress.CommandBusTailLatencyTripwireTest do
  @moduledoc """
  Standing tail-latency SLO tripwire for `AshA2A.CommandBus.run/4` under
  sustained concurrent load (ticket b4p-f5-02 item 2).

  ## The SLO this file enforces

      Under sustained concurrent dispatch, the second half of a run's
      `CommandBus.run/4` p99 latency must stay within
      `degradation_ratio_p99 = late_half_p99 / early_half_p99 <= 3.0`
      of the first half's, with zero dispatch errors.

  The bound is 2x headroom over the worst non-pathological ratio ever
  measured for the default `AshA2A.ReceiptStore.Memory` backend
  (1.274x / 1.515x / 1.391x across the three real runs reported in
  `docs/archive/reports/v26.9.17-commandbus-scale.md`), and far below the
  pathological 181x observed when the host itself was under heavy external
  contention (load average 12-18 on a 16-scheduler host; see
  `docs/archive/reports/v26.9.17-stress-report.md`). The tripwire is therefore
  meaningful on a nominally unloaded host; on a heavily contended host the
  run reports its ratio and may trip -- that is the honest reading, not a
  false positive (an operator signing a Fortune-5 SLO needs to know their
  host contention is destroying their tail).

  `AshA2A.ReceiptStore.Ekv` measured 0.812x-1.072x on the same metric (same
  document) -- callers needing the tightest tail guarantee on contended
  hosts configure `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv`.

  ## Mechanism this tripwire watches (v26.9.17 diagnosis)

  The default `Memory` receipt store is a single `GenServer`: every
  concurrent dispatch funnels its claim / actuation-claim / commit calls
  through one mailbox. When the store process is descheduled (host
  contention, scheduler pressure), its mailbox accumulates and each queued
  call's latency grows -- a tail-heavy (p99-dominated) queueing signature,
  not a uniform slowdown. Additionally, `CommandBus.run/4` calls
  `ReceiptOutbox.count/0` before every dispatch, and `ReceiptOutbox.reconcile/2`
  performs one store `fetch/2` per lingering outbox entry, so per-dispatch
  store traffic scales with outbox debris. This file therefore samples the
  store's real mailbox length every 200 ms and reports the max alongside
  the ratio, so a regression arrives with its mechanism attached, not just
  a red number. The full per-quarter diagnostic evidence behind this
  mechanism statement is in the b4p-f5-02 ticket History / WAVE-RECEIPT.md.

  ## Fail-before / pass-after discipline

  The tripwire must demonstrably FAIL when the pattern it guards appears.
  Set `ASH_A2A_TAIL_TRIPWIRE_FORCE_X` (e.g. `10`) to run the same harness
  with a REAL forced late-half inflation: in the second half of the window
  each worker sleeps `(force - 1) * its own measured dispatch time` inside
  the timed region, manufacturing a genuine ~10x late-half p99 (the
  "forced 10x-worse synthetic"). That run MUST fail the SLO assertion; an
  unforced run on a within-SLO system MUST pass. Both runs' outputs are the
  fail-before/pass-after evidence kept in the ticket History.

  ## Running this file

  Excluded from the default suite (`@moduletag :benchmark`, same convention
  as the sibling stress files). Run explicitly:

      mix test test/ash_a2a/chicago/stress/commandbus_tail_latency_tripwire_test.exs --include benchmark

  Fail-before synthetic:

      ASH_A2A_TAIL_TRIPWIRE_FORCE_X=10 mix test test/ash_a2a/chicago/stress/commandbus_tail_latency_tripwire_test.exs --include benchmark

  Override duration with `ASH_A2A_STRESS_DURATION_MS` (default
  `#{12_000}`), workers with `ASH_A2A_STRESS_WORKERS` (default
  `System.schedulers_online()`).

  The harness deliberately duplicates (a compact form of) the sibling
  `SustainedThroughputTest` loop instead of extracting a shared support
  module: that file's `[SA2A-STRESS-SUSTAINED]` report format is landed,
  documented evidence surface, kept byte-stable here; extraction is a later
  refactor, not this tripwire's job.
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

  # The SLO. See moduledoc: 2x headroom over the worst measured
  # non-pathological Memory ratio (1.515x), vs. the 181x pathological
  # observation this tripwire exists to catch.
  @slo_degradation_ratio_p99 3.0

  @min_half_samples 25

  test "late-half p99 stays within #{Float.to_string(@slo_degradation_ratio_p99)}x early-half p99 under sustained load" do
    duration_ms = duration_ms()
    workers = worker_count()
    force_x = force_x()
    run_id = System.unique_integer([:positive])
    label_prefix = "tail-tripwire-#{run_id}-"

    store_name = Module.concat(__MODULE__, "Store#{run_id}")
    {:ok, store_pid} = start_supervised({AshA2A.ReceiptStore.Memory, name: store_name})
    store_opts = [name: store_name]

    {:ok, _warmup} =
      Item
      |> Ash.Changeset.for_create(:create, %{label: "#{label_prefix}warmup"})
      |> Ash.create(domain: AshA2A.Test.Fixture.ItemDomain)

    outbox_count_before = AshA2A.ReceiptOutbox.count()

    run_started_ms = System.monotonic_time(:millisecond)
    deadline_ms = run_started_ms + duration_ms

    # Light 200 ms mechanism sampler: the store's real mailbox length, so a
    # tripped SLO arrives with its queueing evidence attached (see
    # moduledoc "Mechanism"). Sampling only; never asserted on -- the SLO
    # assertion is the ratio alone.
    test_pid = self()

    sampler =
      spawn(fn ->
        max_mql =
          Enum.reduce_while(1..500, 0, fn _i, max_mql ->
            now = System.monotonic_time(:millisecond)

            if now >= deadline_ms do
              {:halt, max_mql}
            else
              mql =
                case Process.info(store_pid, :message_queue_len) do
                  {:message_queue_len, n} -> n
                  _ -> 0
                end

              Process.sleep(200)
              {:cont, max(max_mql, mql)}
            end
          end)

        send(test_pid, {:tail_tripwire_max_store_mql, max_mql})
      end)

    results =
      1..workers
      |> Task.async_stream(
        fn worker_idx ->
          drive_worker(worker_idx, run_id, label_prefix, deadline_ms, run_started_ms, %{
            capability: @capability,
            store_opts: store_opts,
            force_x: force_x
          })
        end,
        max_concurrency: workers,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, samples} -> samples end)

    wall_ms = System.monotonic_time(:millisecond) - run_started_ms

    # The sampler exits within ~200 ms of the workers' deadline; wait for
    # its final report, never forever.
    max_store_mql =
      receive do
        {:tail_tripwire_max_store_mql, mql} -> mql
      after
        2_000 -> -1
      end

    Process.exit(sampler, :kill)

    ok_samples = Enum.filter(results, &(&1.outcome == :ok))
    error_samples = Enum.filter(results, &(&1.outcome != :ok))

    half_ms = duration_ms / 2
    {early, late} = Enum.split_with(ok_samples, &(&1.start_offset_ms < half_ms))

    early_latency = Bench.distribution(Enum.map(early, & &1.duration_us))
    late_latency = Bench.distribution(Enum.map(late, & &1.duration_us))

    degradation_ratio_p99 =
      ratio(Map.get(late_latency, "p99"), Map.get(early_latency, "p99"))

    degradation_ratio_p50 =
      ratio(Map.get(late_latency, "p50"), Map.get(early_latency, "p50"))

    report = %{
      "run_id" => run_id,
      "workers" => workers,
      "forced_late_half_x" => force_x,
      "requested_duration_ms" => duration_ms,
      "actual_wall_ms" => wall_ms,
      "ok_count" => length(ok_samples),
      "error_count" => length(error_samples),
      "early_half_samples" => length(early),
      "late_half_samples" => length(late),
      "early_half_p99_us" => Map.get(early_latency, "p99"),
      "late_half_p99_us" => Map.get(late_latency, "p99"),
      "degradation_ratio_p50" => degradation_ratio_p50,
      "degradation_ratio_p99" => degradation_ratio_p99,
      "slo_degradation_ratio_p99" => @slo_degradation_ratio_p99,
      "max_store_mailbox_len" => max_store_mql,
      "outbox_count_before" => outbox_count_before,
      "outbox_count_after" => AshA2A.ReceiptOutbox.count()
    }

    IO.puts("\n[SA2A-TAIL-TRIPWIRE] " <> Json.canonical(report))

    # The tripwire's own precondition: real load and both halves populated,
    # zero errors. A run that silently did ~nothing or errored its way
    # through cannot vouch for the ratio either way -- fail closed.
    assert length(early) >= @min_half_samples and length(late) >= @min_half_samples,
           "expected at least #{@min_half_samples} ok dispatches in EACH half of the " <>
             "#{duration_ms}ms window, got early=#{length(early)} late=#{length(late)} -- " <>
             "sustained load did not materialize; the SLO ratio is not measurable"

    assert error_samples == [],
           "expected zero errors under sustained load, got: " <>
             inspect(Enum.take(error_samples, 5))

    # THE SLO.
    assert degradation_ratio_p99 != nil and degradation_ratio_p99 <= @slo_degradation_ratio_p99,
           "TAIL-LATENCY SLO TRIPPED: late-half p99 / early-half p99 = " <>
             "#{inspect(degradation_ratio_p99)}x > #{@slo_degradation_ratio_p99}x " <>
             "(late_half_p99=#{Map.get(late_latency, "p99")}us, " <>
             "early_half_p99=#{Map.get(early_latency, "p99")}us, " <>
             "max_store_mailbox_len=#{max_store_mql}, forced=#{force_x}) -- " <>
             "CommandBus.run/4's tail is climbing under sustained load; see the " <>
             "moduledoc mechanism notes and " <>
             "docs/archive/reports/v26.9.17-commandbus-scale.md"
  end

  defp drive_worker(worker_idx, run_id, label_prefix, deadline_ms, run_started_ms, ctx) do
    principal = Identity.principal("tail-tripwire-worker-#{run_id}-#{worker_idx}")

    authority =
      Authority.new(principal, ctx.capability,
        token_id: "tail-tripwire-auth-#{run_id}-#{worker_idx}"
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

      command =
        Command.new(ctx.capability,
          command_id: "#{label_prefix}cmd-#{worker_idx}-#{seq}",
          agent_id: "tail-tripwire-agent-#{worker_idx}",
          principal_id: principal,
          authority: authority,
          input: %{label: label}
        )

      message = data_message(%{"label" => label})

      start_offset_ms = System.monotonic_time(:millisecond) - run_started_ms
      started_us = System.monotonic_time(:microsecond)
      reply = CommandBus.run(command, message, Item, store_opts: ctx.store_opts)
      elapsed_us = System.monotonic_time(:microsecond) - started_us

      # Forced-synthetic knob (fail-before evidence only, never set in CI):
      # in the LATE half, inflate each dispatch's measured duration by
      # sleeping (force - 1) * its own real elapsed time inside the timed
      # region -- a genuine ~forcex late-half latency manufacture.
      duration_us =
        if is_number(ctx.force_x) and start_offset_ms >= (deadline_ms - run_started_ms) / 2 do
          Process.sleep(trunc(elapsed_us * (ctx.force_x - 1) / 1_000))
          System.monotonic_time(:microsecond) - started_us
        else
          elapsed_us
        end

      sample =
        case reply do
          {:ok, _receipt} ->
            %{outcome: :ok, duration_us: duration_us, start_offset_ms: start_offset_ms}

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

  defp force_x do
    case System.get_env("ASH_A2A_TAIL_TRIPWIRE_FORCE_X") do
      nil -> nil
      raw -> parse_force_x(raw)
    end
  end

  defp parse_force_x(raw) do
    case Float.parse(raw) do
      {x, ""} -> x
      _ -> raise ArgumentError, "invalid ASH_A2A_TAIL_TRIPWIRE_FORCE_X: #{inspect(raw)}"
    end
  end

  defp ratio(_late, nil), do: nil
  defp ratio(nil, _early), do: nil
  defp ratio(_late, 0), do: nil

  defp ratio(late, early) when is_number(late) and is_number(early),
    do: Float.round(late / early, 3)
end
