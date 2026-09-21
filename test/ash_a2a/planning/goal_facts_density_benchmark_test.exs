defmodule AshA2A.Planning.GoalFactsDensityBenchmarkTest do
  @moduledoc """
  Real, safety-bounded density benchmark: how many real, concurrently-ALIVE
  BEAM processes -- each performing one real, representative in-VM decision
  -- this actual host can sustain, closing the "extrapolated design, not
  benchmarked" gap this session's earlier 500M-agent-fleet requirements
  synthesis flagged on every "agents per BEAM node" figure it produced.

  ## Honest substitution (state this every time this file is cited)

  `AshA2A.Planning.HddlDeterministicSynthesis.synthesize/3` shells out to a
  real Rust `hddl_cli` binary via `System.cmd/3` -- spawning that per
  simulated agent at the scales this benchmark targets (up to millions)
  would spawn real OS processes, not lightweight BEAM processes, and would
  genuinely be dangerous at scale on this shared host. This benchmark
  therefore measures `AshA2A.Planning.GoalFacts.admit/2` instead (pure
  Elixir, closed-set/closure validation, zero subprocess) as the
  representative "one agent's real decision". **This benchmarks the
  admission step, not the full solve pipeline** -- do not read its numbers
  as HddlSolver/subprocess throughput; they are not that.

  ## Required invocation

  The default OTP process limit (`:erlang.system_info(:process_limit)`,
  1,048,576 on this host's Erlang/OTP 28 unless raised) sits *below* this
  benchmark's own disclosed 3,000,000-process safety ceiling and below its
  requested top scale (2,000,000). Run this file with the process limit
  raised past both, e.g.:

      ERL_FLAGS="+P 4000000" mix test test/ash_a2a/planning/goal_facts_density_benchmark_test.exs --include benchmark

  Without the raised `+P`, `run_step/5` still degrades honestly: a real
  `SystemLimitError` from the real BEAM VM process limit is caught, the
  real partial spawn count is recorded, and that step is reported with
  `status: :vm_process_limit_hit` -- a distinct, honestly-labeled ceiling
  from this module's own disclosed 3,000,000/4GB bounds below, never
  silently conflated with them.

  ## Safety protocol (real, checked before every step)

  Before each scale step this module checks, against real
  `:erlang.system_info(:process_count)` / `:erlang.memory(:total)` readings:

    1. Would `current_process_count + n` exceed 3,000,000? Skip (and stop
       further scaling) if so.
    2. Using the real per-process memory cost calibrated from the previous
       *successful* step (with a 1.25x safety margin), would this step's
       projected memory delta from this benchmark's very first baseline
       exceed 4,000,000,000 bytes (4 GB)? Skip (and stop further scaling)
       if so.

  This is a deliberate, disclosed safety bound for this session, run on a
  shared host with other real concurrent work -- not necessarily this
  host's true breaking point.

  ## Additional, real-host-observed guard beyond the requested protocol

  At the moment this benchmark was authored, this actual shared host (48GB
  total RAM per this session's real host facts) was observed via a real
  `vm_stat` read to have as little as ~900MB-3.2GB physically free, swinging
  quickly, while several other real, concurrent worktree `mix compile`/
  `mix test` runs were in flight on the same machine. Blindly spending this
  module's full disclosed 4GB memory budget under those real, observed
  conditions would push a host that is *already* under real memory pressure
  into deeper compression/swapping and degrade other real concurrent
  agents' work -- the opposite of "never try to consume more than a small,
  stated fraction of host resources." A third, real-time guard is therefore
  checked before every step, in addition to (never instead of) the two
  disclosed above: a real `vm_stat` read of `Pages free + Pages speculative`
  (converted to bytes via `vm_stat`'s own reported page size).

  This guard is deliberately **proportional to the step's own real
  calibrated cost**, not a flat floor on ambient host-free memory -- an
  earlier version of this guard used a flat 2GB floor and, in real
  execution against this real host, blocked even the smallest (1,000-
  process, ~3MB real cost) step purely because *other* processes had
  transiently driven ambient host-free memory below 2GB, which is not a
  real risk this module's own 1,000-process step poses. The real, corrected
  check: using the real per-process byte cost calibrated from the previous
  *successful* step of the same workload (or a conservative fixed
  first-step estimate, `@host_first_step_bytes_estimate`, before any real
  calibration exists), project this step's real cost and refuse only if
  `real_host_free_bytes - projected_step_cost` would fall below
  `@survival_floor_bytes` (750MB) -- a real "never push this shared host
  below this absolute amount of free memory" line -- or if real host-free
  memory is already below the smaller absolute `@panic_floor_bytes` (300MB)
  regardless of step size, as defense in depth against a wrong projection.
  Either trigger reports status `:skipped_host_memory_pressure` and stops
  further scaling for that workload -- honestly reported as a real
  host-condition-driven stop, distinct from this module's own two disclosed
  static bounds above.

  Runs inside its own isolated `mix test` ExUnit process (never the shared
  application's own running instance), tagged `@moduletag :benchmark` and
  excluded from the default `mix test` run via `test/test_helper.exs`'s
  `ExUnit.start(exclude: [:external_api, :benchmark])` -- the same
  established exclusion pattern this repo already uses for `:external_api`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Planning.GoalFacts
  alias AshA2A.Test.Fixture.HddlDeterministicFixture

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @advance_id "AshA2A.Test.Fixture.HddlDeterministicFixture.advance"
  @unlock_id "AshA2A.Test.Fixture.HddlDeterministicFixture.unlock"

  @scales [1_000, 10_000, 100_000, 500_000, 1_000_000, 2_000_000]
  @max_process_count 3_000_000
  @max_memory_delta_bytes 4_000_000_000
  @survival_floor_bytes 750_000_000
  @panic_floor_bytes 300_000_000
  @host_first_step_bytes_estimate 10_000
  @safety_margin 1.25
  @drain_tolerance 500

  defp goal_facts_envelope do
    %{
      "request_id" => nil,
      "domain_name" => "density-benchmark-domain",
      "problem_name" => "density-benchmark-problem",
      "objects" => ["on", "off"],
      "init" => [%{"predicate" => "current_phase", "args" => ["on"]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => ["off"]},
        %{"predicate" => "has_key", "args" => ["off"]}
      ],
      "task_sequence" => [
        %{"capability_id" => @advance_id, "args" => ["on", "off"]},
        %{"capability_id" => @unlock_id, "args" => ["off"]}
      ]
    }
  end

  test "real concurrent-process density ceiling: GoalFacts.admit/2 vs idle BEAM processes" do
    envelope = goal_facts_envelope()

    # Real, single, up-front proof that the envelope every spawned process
    # below will admit against is actually admissible against the real
    # compiled fixture -- run once, outside the timed/measured protocol, so
    # a broken envelope fails loudly here instead of silently degrading
    # every worker's real work into an ignored `{:error, _}`.
    assert {:ok, admitted} = GoalFacts.admit(HddlDeterministicFixture, envelope)
    assert admitted.capability_ids == [@advance_id, @unlock_id]

    first_baseline_memory = :erlang.memory(:total)
    first_baseline_count = :erlang.system_info(:process_count)

    IO.puts("\n=== GoalFacts density benchmark -- first real baseline ===")
    IO.puts("process_count=#{first_baseline_count} memory_total_bytes=#{first_baseline_memory}")

    admit_results = run_scales(@scales, :goal_facts_admit, envelope, first_baseline_memory)
    idle_results = run_scales(@scales, :idle, envelope, first_baseline_memory)

    print_table("workload: AshA2A.Planning.GoalFacts.admit/2 (real decision)", admit_results)
    print_table("workload: idle `receive do :go -> :ok end` (raw BEAM capacity)", idle_results)

    print_extrapolation("admit/2 workload", admit_results)
    print_extrapolation("idle workload", idle_results)

    assert Enum.any?(admit_results, &(&1.status == :ok)),
           "no admit/2 scale step completed successfully -- real ceiling was hit at the smallest requested scale"

    assert Enum.any?(idle_results, &(&1.status == :ok)),
           "no idle scale step completed successfully -- real ceiling was hit at the smallest requested scale"
  end

  # -- scale-step orchestration (safety checks run BEFORE every step) --------

  defp run_scales(scales, mode, envelope, first_baseline_memory) do
    run_scales(scales, mode, envelope, first_baseline_memory, nil, [])
  end

  defp run_scales([], _mode, _envelope, _first_baseline_memory, _prior_bytes, acc),
    do: Enum.reverse(acc)

  defp run_scales([n | rest], mode, envelope, first_baseline_memory, prior_bytes, acc) do
    current_count = :erlang.system_info(:process_count)
    current_memory = :erlang.memory(:total)
    host_free = host_free_bytes()

    host_projection = projected_host_free_after_step(host_free, prior_bytes, n)

    cond do
      is_integer(host_free) and host_free < @panic_floor_bytes ->
        result = %{
          n: n,
          mode: mode,
          status: :skipped_host_memory_pressure,
          reason:
            "real vm_stat host-free-memory read #{host_free} bytes is already below the " <>
              "absolute #{@panic_floor_bytes}-byte panic floor, regardless of this step's own " <>
              "size -- this shared host is under real memory pressure from other concurrent " <>
              "work right now; stopping before this module's own disclosed " <>
              "3,000,000-process/4GB bounds would even be tested"
        }

        Enum.reverse([result | acc])

      is_integer(host_projection) and host_projection < @survival_floor_bytes ->
        result = %{
          n: n,
          mode: mode,
          status: :skipped_host_memory_pressure,
          reason:
            "real host-free memory #{host_free} bytes minus this step's own real-calibrated " <>
              "projected cost would leave #{host_projection} bytes free, below the " <>
              "#{@survival_floor_bytes}-byte survival floor -- this shared host is under real " <>
              "memory pressure from other concurrent work right now; stopping before this " <>
              "module's own disclosed 3,000,000-process/4GB bounds would even be tested"
        }

        Enum.reverse([result | acc])

      current_count + n > @max_process_count ->
        result = %{
          n: n,
          mode: mode,
          status: :skipped_process_ceiling,
          reason:
            "current process_count #{current_count} + n #{n} would exceed the disclosed " <>
              "#{@max_process_count} safety ceiling"
        }

        Enum.reverse([result | acc])

      projected_memory_delta(prior_bytes, n, current_memory, first_baseline_memory) >
          @max_memory_delta_bytes ->
        projected = projected_memory_delta(prior_bytes, n, current_memory, first_baseline_memory)

        result = %{
          n: n,
          mode: mode,
          status: :skipped_memory_ceiling,
          reason:
            "projected memory delta #{projected} bytes (#{@safety_margin}x-margined, " <>
              "calibrated from the prior successful step's real per-process cost) would " <>
              "exceed the disclosed #{@max_memory_delta_bytes}-byte safety ceiling"
        }

        Enum.reverse([result | acc])

      true ->
        result = run_step(n, mode, envelope, current_count, first_baseline_memory)

        case result.status do
          :ok ->
            per_process_bytes = result.peak_memory_delta_bytes / n

            run_scales(rest, mode, envelope, first_baseline_memory, per_process_bytes, [
              result | acc
            ])

          _other ->
            Enum.reverse([result | acc])
        end
    end
  end

  defp projected_memory_delta(nil, _n, current_memory, first_baseline_memory) do
    # No real calibration data yet (this is the first scale step) -- cannot
    # honestly project, so report only the real current delta and let this
    # (small, first) real step run to calibrate from its own measurement.
    current_memory - first_baseline_memory
  end

  defp projected_memory_delta(prior_per_process_bytes, n, current_memory, first_baseline_memory) do
    current_memory - first_baseline_memory + trunc(prior_per_process_bytes * n * @safety_margin)
  end

  # Real, proportional host-free-memory projection for the third disclosed
  # guard -- see this module's moduledoc "Additional, real-host-observed
  # guard" section for why this is proportional to the step's own real
  # calibrated cost rather than a flat floor on ambient host-free memory.
  # Returns :unknown (never blocks scaling on its own) when `host_free`
  # itself is :unknown (vm_stat unavailable on this platform).
  defp projected_host_free_after_step(:unknown, _prior_bytes, _n), do: :unknown

  defp projected_host_free_after_step(host_free, nil, n) when is_integer(host_free) do
    # No real per-process calibration yet (first step of this workload) --
    # use a conservative fixed estimate rather than skip the projection
    # entirely, so a first step still gets a real proportional check.
    host_free - n * @host_first_step_bytes_estimate
  end

  defp projected_host_free_after_step(host_free, prior_per_process_bytes, n)
       when is_integer(host_free) do
    host_free - trunc(prior_per_process_bytes * n * @safety_margin)
  end

  # Real host-wide (not this-VM-only) free-memory read, additional to the
  # two disclosed static bounds -- see this module's moduledoc "Additional,
  # real-host-observed guard" section for why this exists. Returns bytes, or
  # `:unknown` (never blocks scaling) if `vm_stat` is unavailable on this
  # platform -- fails open to the two disclosed bounds rather than silently
  # refusing to run at all on a non-macOS host.
  defp host_free_bytes do
    case System.cmd("vm_stat", []) do
      {output, 0} ->
        with page_size when is_integer(page_size) <- extract_page_size(output),
             free when is_integer(free) <- extract_pages(output, "Pages free"),
             speculative when is_integer(speculative) <-
               extract_pages(output, "Pages speculative") do
          (free + speculative) * page_size
        else
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  rescue
    ErlangError -> :unknown
  end

  defp extract_page_size(output) do
    case Regex.run(~r/page size of (\d+) bytes/, output) do
      [_, size] -> String.to_integer(size)
      _ -> nil
    end
  end

  defp extract_pages(output, label) do
    case Regex.run(~r/#{Regex.escape(label)}:\s+(\d+)\./, output) do
      [_, count] -> String.to_integer(count)
      _ -> nil
    end
  end

  # -- one real step: spawn N blocked -> read peak -> release -> drain -------

  defp run_step(n, mode, envelope, baseline_count, first_baseline_memory) do
    parent = self()
    worker_fun = worker_fun(mode, envelope, parent)
    wall_start = System.monotonic_time(:millisecond)

    case spawn_n(n, worker_fun) do
      {:system_limit, pids, spawned} ->
        # Real, honest degradation: the actual BEAM VM process limit (not
        # this module's own disclosed 3,000,000/4,000,000,000 bound) was
        # hit mid-spawn. Release whatever was actually spawned, drain, and
        # report the real partial count -- never silently rounded up to n.
        Enum.each(pids, &send(&1, :go))
        _ = await_done(spawned, System.monotonic_time(:millisecond) + step_timeout_ms(spawned))

        _ =
          wait_until_near_baseline(
            baseline_count,
            System.monotonic_time(:millisecond) + step_timeout_ms(spawned)
          )

        %{
          n: n,
          mode: mode,
          status: :vm_process_limit_hit,
          spawned: spawned,
          reason:
            "real SystemLimitError from :erlang.system_info(:process_limit) after " <>
              "spawning #{spawned} of #{n} requested -- raise the OTP process limit " <>
              "(e.g. ERL_FLAGS=\"+P 4000000\") to exercise this module's own disclosed " <>
              "3,000,000-process ceiling instead of the VM default"
        }

      {:ok, pids} ->
        peak_count = :erlang.system_info(:process_count)
        peak_memory = :erlang.memory(:total)

        Enum.each(pids, &send(&1, :go))

        acked = await_done(n, System.monotonic_time(:millisecond) + step_timeout_ms(n))

        final_count =
          wait_until_near_baseline(
            baseline_count,
            System.monotonic_time(:millisecond) + step_timeout_ms(n)
          )

        final_memory = :erlang.memory(:total)
        wall_end = System.monotonic_time(:millisecond)

        status =
          cond do
            acked < n -> :incomplete_acks
            final_count > baseline_count + @drain_tolerance -> :drain_incomplete
            true -> :ok
          end

        %{
          n: n,
          mode: mode,
          status: status,
          acked: acked,
          peak_process_count: peak_count,
          peak_process_count_delta: peak_count - baseline_count,
          peak_memory_delta_bytes: peak_memory - first_baseline_memory,
          final_process_count: final_count,
          final_memory_delta_bytes: final_memory - first_baseline_memory,
          wall_clock_ms: wall_end - wall_start
        }
    end
  end

  defp worker_fun(:goal_facts_admit, envelope, parent) do
    fn ->
      receive do
        :go ->
          GoalFacts.admit(HddlDeterministicFixture, envelope)
          send(parent, {:done, self()})
      end
    end
  end

  defp worker_fun(:idle, _envelope, parent) do
    fn ->
      receive do
        :go -> send(parent, {:done, self()})
      end
    end
  end

  defp spawn_n(n, worker_fun), do: spawn_n(n, worker_fun, 0, [])

  defp spawn_n(0, _worker_fun, _count, acc), do: {:ok, acc}

  defp spawn_n(n, worker_fun, count, acc) when n > 0 do
    try do
      pid = spawn(worker_fun)
      spawn_n(n - 1, worker_fun, count + 1, [pid | acc])
    rescue
      SystemLimitError -> {:system_limit, acc, count}
    end
  end

  defp step_timeout_ms(n), do: max(30_000, div(n, 10))

  defp await_done(n, deadline), do: await_done_loop(n, 0, deadline)

  defp await_done_loop(n, acc, _deadline) when acc >= n, do: acc

  defp await_done_loop(n, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {:done, _pid} -> await_done_loop(n, acc + 1, deadline)
      after
        remaining -> acc
      end
    end
  end

  defp wait_until_near_baseline(baseline_count, deadline) do
    count = :erlang.system_info(:process_count)

    cond do
      count <= baseline_count + @drain_tolerance ->
        count

      System.monotonic_time(:millisecond) >= deadline ->
        count

      true ->
        Process.sleep(20)
        wait_until_near_baseline(baseline_count, deadline)
    end
  end

  # -- reporting ---------------------------------------------------------------

  defp print_table(title, results) do
    IO.puts("\n--- #{title} ---")

    header =
      [
        pad("n", 10),
        pad("status", 22),
        pad("peak_count_delta", 18),
        pad("peak_mem_delta_B", 18),
        pad("final_mem_delta_B", 18),
        pad("wall_clock_ms", 14)
      ]
      |> Enum.join()

    IO.puts(header)

    Enum.each(results, fn r ->
      row =
        [
          pad(r.n, 10),
          pad(r.status, 22),
          pad(Map.get(r, :peak_process_count_delta, "-"), 18),
          pad(Map.get(r, :peak_memory_delta_bytes, "-"), 18),
          pad(Map.get(r, :final_memory_delta_bytes, "-"), 18),
          pad(Map.get(r, :wall_clock_ms, "-"), 14)
        ]
        |> Enum.join()

      IO.puts(row)

      if Map.has_key?(r, :reason), do: IO.puts("    reason: #{r.reason}")
    end)
  end

  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)

  defp print_extrapolation(label, results) do
    case Enum.filter(results, &(&1.status == :ok)) |> List.last() do
      nil ->
        IO.puts(
          "\n#{label}: no successful step -- no real peak-per-node figure to extrapolate from"
        )

      %{n: n} ->
        nodes_needed = 500_000_000 / n
        IO.puts("\n#{label} real peak-per-node figure: #{n}")
        IO.puts("500,000,000 / #{n} = #{nodes_needed} real nodes required (unrounded)")
    end
  end
end
