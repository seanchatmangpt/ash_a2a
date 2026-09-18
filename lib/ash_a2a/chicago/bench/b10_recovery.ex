defmodule AshA2A.Chicago.Bench.B10Recovery do
  @moduledoc """
  RFC-SA2A-002 §94 benchmark `SA2A-B10` -- crash/reconciliation recovery,
  extracted into the standalone bench interface from the real measurement
  already embedded in `AshA2A.Chicago.Courts.CrashReconciliation`
  (`SA2A-CHAOS-018`, its falsifier `fid(18)`).

  Exercises the exact same real crash-point sweep the court measures -- no
  new operation is invented: five real §70 crash points, each

    1. `Environment.run_crashing/4` -- the real `AshA2A.CommandBus.run/4` over
       the real consequence-bearing `ChaosReconciliation.Effect` action, with
       the executing process killed (`:kill`) at the real boundary event (or
       stalled mid external-call) named by the crash point;
    2. `Environment.restart_store/1` -- the real on-disk EKV tree killed and
       restarted over the same data dir;
    3. `AshA2A.Reconciliation.classify/4` then `.reconcile/4` -- the real
       durable-evidence classifier and recovery path, probing the external
       ledger (`Environment.probe/1`) only when still `prepared_unknown_outcome`;
    4. `Environment.run/4` -- the real resubmission through `CommandBus.run/4`;
       zero repeated external effects (ledger rows beyond one per command id,
       §94) is the invariant, exactly as the court enforces it.

  Crash points, same as the court:

    * before receipt preparation (`brce.claim(execute)`)
    * after preparation, before the external call (`brce.prepare(prepared)`)
    * during the external call (stalled, then killed)
    * after the external response, before finalization (`actuate.stop`)
    * after finalization, before acknowledgement (`brce.commit(committed)`)

  One measured iteration is the full five-point sweep (a `Bench.sample()` per
  point, `"case" => "b10_<point>"`), the same grouping the court's own
  `crash_points_reached` / `repeated_external_effects_total` rollup uses.
  `duration_us` per sample is the real recovery time -- crash to resubmission
  classified `:reconciled` -- not the whole point's wall time (crash injection
  and store restart are excluded, same split the court's own `recovery_ms`
  measures).

  Defaults to 1 measured iteration and 0 warmup (`iterations: 1, warmup: 0`)
  unless the caller overrides: one sweep kills and restarts a real durable
  store five times and one crash point stalls an external call before killing
  it, so this is not a hot-path microbenchmark.
  """

  alias AshA2A.{Identity, Reconciliation}
  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment, as: Env

  @id "SA2A-B10"

  @claim [:ash_a2a, :command_bus, :claim]
  @prepare [:ash_a2a, :command_bus, :prepare]
  @actuate_stop [:ash_a2a, :command_bus, :actuate, :stop]
  @commit [:ash_a2a, :command_bus, :commit]
  @stall_ms 30_000

  @points [
    {"before_receipt_preparation", %{}, {:at_event, @claim, %{outcome: :execute}}},
    {"after_preparation_before_external_call", %{}, {:at_event, @prepare, %{outcome: :prepared}}},
    {"during_external_call", %{"hang_after_ms" => @stall_ms}, :during_external_call},
    {"after_external_response_before_finalization", %{}, {:at_event, @actuate_stop, %{}}},
    {"after_finalization_before_acknowledgement", %{},
     {:at_event, @commit, %{outcome: :committed}}}
  ]

  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Runs the benchmark. Always `{:ok, body}` -- every crash point runs against a
  fresh real `ChaosReconciliation.Environment` on this machine; there is no
  external runtime precondition to be unavailable (unlike B7/B9).

  Options: `:iterations` (default 1), `:warmup` (default 0).
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    {:ok, measure(opts)}
  end

  defp measure(opts) do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    run_opts = opts |> Keyword.put_new(:iterations, 1) |> Keyword.put_new(:warmup, 0)

    measured =
      Bench.measure(fn phase, i -> sweep(phase, i, collector) end, run_opts)

    raw = collector |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(collector)

    measured_points = Enum.filter(raw, &(&1["phase"] == :measured))
    repeated = measured_points |> Enum.map(& &1["repeated_external_effects"]) |> Enum.sum()

    Map.merge(measured, %{
      "benchmark" => "B10 crash/reconciliation recovery",
      "rfc_sections" => ["§70", "§94"],
      "sut" => %{
        "actuation" => "AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment.run_crashing/4",
        "store_restart" =>
          "AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment.restart_store/1",
        "classify_reconcile" =>
          "AshA2A.Reconciliation.classify/4, AshA2A.Reconciliation.reconcile/4",
        "resubmission" => "AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment.run/4"
      },
      "failure_points" => Enum.map(@points, &elem(&1, 0)),
      "points" => raw,
      "crash_points_reached" => Enum.count(measured_points, & &1["crash_point_reached"]),
      "repeated_external_effects_total" => repeated,
      "environment" => environment(),
      "highlights" => %{
        "recovery_us_p50" => measured["latency_us"]["p50"],
        "recovery_us_p99" => measured["latency_us"]["p99"],
        "repeated_external_effects_total" => repeated
      }
    })
  end

  defp sweep(phase, i, collector) do
    Enum.map(@points, &point_sample(&1, phase, i, collector))
  end

  defp point_sample({point, extra, crash}, phase, i, collector) do
    root =
      Path.join([fresh_root(), "sweep-#{phase}-#{i}", point])

    env = Env.open(root)

    try do
      cid = "sa2a-b10-#{point}-#{System.unique_integer([:positive])}"
      input = Map.merge(%{"operation_id" => cid}, extra)

      crashed = Env.run_crashing(env, cid, input, crash)
      rows_after_crash = Env.rows(cid)

      started = System.monotonic_time(:microsecond)
      env = Env.restart_store(env)

      post =
        Reconciliation.classify(Identity.command(cid), Env.store(), Env.store_opts(env),
          label: "bench.b10.post_crash"
        )

      recovery =
        Reconciliation.reconcile(Identity.command(cid), Env.store(), Env.store_opts(env),
          label: "bench.b10.recovery",
          probe: &Env.probe/1
        )

      recovery_us = System.monotonic_time(:microsecond) - started
      resubmission = Env.run(env, cid, input)

      final =
        Reconciliation.classify(Identity.command(cid), Env.store(), Env.store_opts(env),
          label: "bench.b10.final"
        )

      rows = Env.rows(cid)
      repeated = max(rows - 1, 0)

      detail = %{
        "phase" => phase,
        "iteration" => i,
        "failure_point" => point,
        "crash_point_reached" => crashed.crash_point_reached?,
        "rows_after_crash" => rows_after_crash,
        "post_crash_state" => state(post),
        "recovery_ms" => Float.round(recovery_us / 1000, 3),
        "reconciliation_outcome" => recovery_outcome(recovery),
        "final_state" => state(final),
        "resubmission_status" => resubmission_status(resubmission),
        "repeated_external_effects" => repeated
      }

      Agent.update(collector, &[detail | &1])

      %{
        case: "b10_#{point}",
        duration_us: recovery_us,
        outcome: to_string(state(final)),
        invariant: invariant(crashed, repeated)
      }
    after
      Env.close(env)
    end
  end

  defp state({:ok, %{state: state}}), do: state
  defp state(_), do: :unavailable

  defp recovery_outcome({:ok, %{outcome: outcome}}), do: outcome
  defp recovery_outcome(other), do: inspect(other)

  defp resubmission_status({:ok, %{status: status}}), do: to_string(status)
  defp resubmission_status({:error, %{code: code}}), do: "error:#{code}"
  defp resubmission_status(other), do: inspect(other, limit: 5)

  defp invariant(%{crash_point_reached?: false}, _repeated),
    do: {:error, "crash point was not reached"}

  defp invariant(_crashed, 0), do: :ok

  defp invariant(_crashed, repeated),
    do: {:error, "#{repeated} repeated external effect(s) observed (desired 0, §94)"}

  defp environment do
    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "store" => inspect(Env.store()),
      "store_mode" => "EKV member, cluster_size 1, on-disk SQLite, killed and restarted per point"
    }
  end

  defp fresh_root do
    Path.join([
      System.tmp_dir!(),
      "ash_a2a_bench",
      @id,
      Integer.to_string(System.unique_integer([:positive]))
    ])
  end
end
