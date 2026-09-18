defmodule AshA2A.Chicago.Bench.B8Replay do
  @moduledoc """
  RFC-SA2A-002 §92 benchmark `SA2A-B8` -- offline replay reconstruction,
  extracted into the standalone bench interface from the real measurement
  already embedded in `AshA2A.Chicago.Courts.OfflineReplay` (`CHI-REPLAY-009`).

  Exercises the exact same real operation the court measures -- no new
  operation is invented:

    * `AshA2A.Chicago.Fixtures.Replay.produce/3` drives the real
      `AshA2A.CommandBus` over the real SA2A-CHAOS external-domain ledger with
      the real durable stores of a `ChaosReconciliation.Environment`
      (on-disk EKV primary store + `AshA2A.ReceiptOutbox` journal), sealing a
      real `AshA2A.Receipt.EvidenceChain` from a producer process this module
      kills once sealed -- once per chain size, same as the court.
    * `AshA2A.Receipt.OfflineReplay.verify_fresh/2` is the boundary under
      measurement for the "genuinely fresh OS process, no producer memory"
      path: it spawns a real `elixir` OS process with no `:ash_a2a` started
      and no DO boundary module loaded, and its own internal
      `"measurements"` (`verify_us`, `peak_vm_total_bytes`,
      `baseline_vm_total_bytes`, `startup_us`, `total_us`) are the real,
      already-embedded numbers this module reports, not re-derived.
    * `AshA2A.Receipt.OfflineReplay.replay/2` is the in-VM path (actuator
      reachable but never called), whose `"measurements"`
      (`verify_us`, `peak_verifier_bytes`) are likewise the real embedded
      numbers.
    * External-domain ledger rows before/after (`Fx.rows/1`, an independent
      `Ash.read!` reader) verify zero external consequence (§84) on every
      replay, same invariant the court enforces.

  Real chain sizes, same as the court: #{inspect([2, 8, 32])} executed effects
  (plus one deduplicated retry `Fx.produce/3` always appends). Each size's
  chain is produced and sealed once, before `Bench.measure/2`'s warmup/measured
  loop -- the same "build fixtures once, measure the repeated call" shape as
  `AshA2A.Chicago.Bench.B1Admission`; only `verify_fresh/2` and `replay/2`
  (each spawning fresh work) run per iteration.

  Defaults to 1 measured iteration and 0 warmup (`iterations: 1, warmup: 0`)
  unless the caller overrides: `verify_fresh/2` spawns a real OS `elixir`
  process per call and is not a hot-path microbenchmark.
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment
  alias AshA2A.Chicago.Fixtures.Replay, as: Fx
  alias AshA2A.Receipt.OfflineReplay

  @id "SA2A-B8"
  @sizes [2, 8, 32]

  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when
  producing even the first real evidence chain fails (never a fake chain).

  Options: `:iterations` (default 1), `:warmup` (default 0), `:sizes`
  (default #{inspect(@sizes)}).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    root = fresh_root()
    env = Environment.open(root)

    try do
      case produce_chains(env, root, Keyword.get(opts, :sizes, @sizes)) do
        {:ok, chains} -> {:ok, measure(chains, opts)}
        {:error, reason} -> {:blocked, "evidence chain production failed: #{inspect(reason)}"}
      end
    after
      Environment.close(env)
    end
  end

  defp produce_chains(env, root, sizes) do
    result =
      Enum.reduce_while(sizes, {:ok, []}, fn n, {:ok, acc} ->
        dir = Path.join(root, "chain-#{n}")

        case Fx.produce(env, dir, executed: n) do
          {:ok, pkg} -> {:cont, {:ok, [Map.put(pkg, :n, n) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp measure(chains, opts) do
    {:ok, collector} = Agent.start_link(fn -> [] end)
    run_opts = opts |> Keyword.put_new(:iterations, 1) |> Keyword.put_new(:warmup, 0)

    measured =
      Bench.measure(
        fn phase, i -> Enum.map(chains, &replay_sample(&1, phase, i, collector)) end,
        run_opts
      )

    raw = collector |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(collector)

    Map.merge(measured, %{
      "benchmark" => "B8 offline replay reconstruction",
      "rfc_sections" => ["§41", "§84", "§92"],
      "sut" => %{
        "producer" => "AshA2A.Chicago.Fixtures.Replay.produce/3",
        "fresh_os_process" => "AshA2A.Receipt.OfflineReplay.verify_fresh/2",
        "in_vm" => "AshA2A.Receipt.OfflineReplay.replay/2"
      },
      "chain_sizes" => Enum.map(chains, & &1.n),
      "sizes" => raw,
      "zero_external_consequence" => Enum.all?(raw, &(&1["ledger_rows_delta"] == 0)),
      "environment" => environment(),
      "highlights" => %{
        "fresh_verify_p50_us" => measured["latency_us"]["p50"],
        "fresh_verify_p99_us" => measured["latency_us"]["p99"],
        "max_receipt_chain_length" =>
          raw |> Enum.map(& &1["receipt_chain_length"]) |> Enum.max(fn -> nil end)
      }
    })
  end

  defp replay_sample(pkg, phase, i, collector) do
    anchor = [
      link_root: pkg.seal["link_root"],
      basis_root: pkg.seal["basis_root"],
      producer: pkg.pid
    ]

    before = Fx.rows(pkg.operations)
    started = System.monotonic_time(:microsecond)
    {:ok, fresh} = OfflineReplay.verify_fresh(pkg.dir, anchor)
    {:ok, in_vm} = OfflineReplay.replay(pkg.dir, anchor)
    duration = System.monotonic_time(:microsecond) - started
    delta = Fx.rows(pkg.operations) - before

    fm = fresh["measurements"] || %{}
    vm = in_vm["measurements"] || %{}

    detail = %{
      "phase" => phase,
      "iteration" => i,
      "n" => pkg.n,
      "receipt_chain_length" => pkg.seal["length"],
      "serialized_evidence_bytes" => pkg.seal["evidence_bytes"],
      "outcomes" => %{"fresh_os_process" => fresh["outcome"], "in_vm" => in_vm["outcome"]},
      "replay_verification_us" => %{
        "fresh_os_process" => fm["verify_us"],
        "in_vm" => vm["verify_us"]
      },
      "peak_memory_bytes" => %{
        "fresh_vm_total" => fm["peak_vm_total_bytes"],
        "fresh_vm_baseline" => fm["baseline_vm_total_bytes"],
        "in_vm_verifier_process" => vm["peak_verifier_bytes"]
      },
      "fresh_consumer_startup_us" => fm["startup_us"],
      "fresh_consumer_total_us" => fm["total_us"],
      "fresh_do_boundary_loaded" => get_in(fresh, ["process", "do_boundary_loaded"]),
      "ledger_rows_delta" => delta
    }

    Agent.update(collector, &[detail | &1])

    %{
      case: "b8_size_#{pkg.n}",
      duration_us: duration,
      outcome: fresh["outcome"],
      phases: %{
        "fresh_verify_us" => fm["verify_us"],
        "in_vm_verify_us" => vm["verify_us"],
        "fresh_startup_us" => fm["startup_us"]
      },
      invariant: invariant(fresh, in_vm, delta)
    }
  end

  defp invariant(fresh, in_vm, delta) do
    cond do
      fresh["outcome"] != "verified" ->
        {:error, "fresh OS process did not verify: #{inspect(fresh["outcome"])}"}

      in_vm["outcome"] != "verified" ->
        {:error, "in-VM replay did not verify: #{inspect(in_vm["outcome"])}"}

      get_in(fresh, ["process", "do_boundary_loaded"]) != false ->
        {:error, "fresh process loaded a DO boundary module"}

      delta != 0 ->
        {:error, "replay moved the external ledger by #{delta} row(s)"}

      true ->
        :ok
    end
  end

  defp environment do
    %{
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "system_architecture" => to_string(:erlang.system_info(:system_architecture)),
      "schedulers_online" => :erlang.system_info(:schedulers_online)
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
