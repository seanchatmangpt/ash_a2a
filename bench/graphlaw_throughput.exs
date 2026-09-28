# bench/graphlaw_throughput.exs
#
# GraphLaw engine latency + throughput bench (PERF-11). Real engine, real
# Wasmtime instances, real `node` only where a node runtime is named; nothing
# simulated.
#
#     mix run bench/graphlaw_throughput.exs [--iterations 200] [--levels 1,8,32,128]
#                                           [--check] [--pool N]
#
# Measures:
#
#   (a) `AshA2A.GraphLaw.WasmexSession.open/1` latency (first = compile, then
#       warm opens from the compiled-module cache);
#   (b) per-call latency of `GraphLawBridge.graph_hash/2`,
#       `Semantic.GraphLaw.validate/3` (the Peer admission engine call) and
#       `Semantic.CanonicalDigest.canonical_digest/2`;
#   (c) a concurrency sweep of `GraphLawBridge.graph_hash/2` at each level c:
#       ops/s, p50/p99, `WasmexHost` mailbox length and `:erlang.memory(:total)`
#       before and after.
#
# `--pool N` starts an `AshA2A.GraphLaw.WasmexPool` of N members first (when
# the application did not already start one), so the default-name routing
# spreads load across members.
#
# `--check` enforces the admitted regression bounds below and exits 1 on any
# violation, so this script is a gate, not only a report.

defmodule AshA2A.Bench.GraphLawThroughput do
  @moduledoc false

  alias AshA2A.GraphLaw.{WasmexHost, WasmexPool, WasmexSession}
  alias AshA2A.Semantic.{CanonicalDigest, GraphLaw, GraphLawBridge}

  @ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"

  # Admitted bounds (microseconds / ops per second). Measured 2026-09-27 on
  # the vendored artifact: a Cranelift compile was 1.04-1.22 s per open before
  # the compiled-module cache and ~100 ms per node-transport call before the
  # warm host. The bounds sit well above the warm measurements and well below
  # the pre-fix ones, so either regression trips them.
  @bounds %{
    "open_warm_us.p99" => 300_000,
    "graph_hash_us.p99" => 5_000,
    "validate_us.p99" => 20_000,
    "canonical_digest_us.p99" => 20_000,
    "throughput_ops_s(c=32)" => 1_000
  }

  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [iterations: :integer, levels: :string, check: :boolean, pool: :integer]
      )

    iterations = Keyword.get(opts, :iterations, 200)

    levels =
      opts
      |> Keyword.get(:levels, "1,8,32,128")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer/1)

    maybe_pool(Keyword.get(opts, :pool))
    wait_loaded()

    IO.puts(
      "graphlaw throughput bench -- host #{inspect(GraphLawBridge.host())}, " <>
        "pool members #{length(WasmexPool.members())}"
    )

    {first_us, {:ok, %{session: s}}} = :timer.tc(fn -> WasmexSession.open([]) end)
    WasmexSession.close(s)
    IO.puts("\nWasmexSession.open first: #{first_us} us")

    open =
      samples(10, fn ->
        {:ok, %{session: s}} = WasmexSession.open([])
        WasmexSession.close(s)
      end)

    graph_hash = samples(iterations, fn -> {:ok, _} = GraphLawBridge.graph_hash(@ttl) end)
    validate = samples(iterations, fn -> {:ok, _} = GraphLaw.validate(@ttl, "") end)

    triple = %{subject: "http://e/a", predicate: "http://e/p", object: {:iri, "http://e/b"}}
    digest = samples(iterations, fn -> {:ok, _} = CanonicalDigest.canonical_digest([triple]) end)

    measured =
      %{}
      |> Map.merge(report("WasmexSession.open (warm)", "open_warm_us", open))
      |> Map.merge(report("GraphLawBridge.graph_hash", "graph_hash_us", graph_hash))
      |> Map.merge(report("Semantic.GraphLaw.validate", "validate_us", validate))
      |> Map.merge(report("CanonicalDigest.canonical_digest", "canonical_digest_us", digest))

    measured =
      Enum.reduce(levels, measured, fn c, acc -> Map.merge(acc, sweep(c, iterations * 2)) end)

    if Keyword.get(opts, :check, false), do: check(measured)
  end

  defp maybe_pool(nil), do: :ok

  defp maybe_pool(n) do
    if WasmexPool.members() == [] do
      host = Process.whereis(WasmexHost)
      if host, do: Supervisor.terminate_child(AshA2A.Supervisor, WasmexHost)
      {:ok, _} = WasmexPool.start_link(size: n)
    end

    :ok
  end

  defp wait_loaded(tries \\ 200) do
    cond do
      WasmexHost.loaded_sha256() -> :ok
      tries == 0 -> raise "WasmexHost never loaded the pinned engine"
      true -> Process.sleep(50) && wait_loaded(tries - 1)
    end
  end

  defp samples(n, fun) do
    for _ <- 1..3, do: fun.()
    for(_ <- 1..n, do: elem(:timer.tc(fun), 0)) |> Enum.sort()
  end

  defp sweep(c, n) do
    mem_before = :erlang.memory(:total)
    started = System.monotonic_time(:microsecond)
    parent = self()

    sampler =
      spawn(fn -> queue_sampler(parent, 0) end)

    results =
      1..n
      |> Task.async_stream(fn _ -> :timer.tc(fn -> GraphLawBridge.graph_hash(@ttl) end) end,
        max_concurrency: c,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, timed} -> timed end)

    # Only answered calls count toward throughput and latency; a call shed
    # with :graphlaw_saturated is reported separately, never as an op.
    {ok, failed} = Enum.split_with(results, fn {_us, result} -> match?({:ok, _}, result) end)
    lat = ok |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    lat = if lat == [], do: [0], else: lat

    shed =
      Enum.count(failed, fn {_us, result} ->
        match?({:error, %{code: :graphlaw_saturated}}, result)
      end)

    wall = max(System.monotonic_time(:microsecond) - started, 1)
    send(sampler, :stop)

    max_queue =
      receive do
        {:max_queue, q} -> q
      after
        1_000 -> nil
      end

    ops = Float.round(length(ok) * 1_000_000 / wall, 1)

    IO.puts(
      "\nsweep c=#{c}: #{ops} ops/s  ok=#{length(ok)} shed=#{shed} " <>
        "other_errors=#{length(failed) - shed}  p50=#{pct(lat, 50)} us  p99=#{pct(lat, 99)} us  " <>
        "max_host_queue=#{inspect(max_queue)}  mem_before=#{mem_before}  " <>
        "mem_after=#{:erlang.memory(:total)}"
    )

    %{
      "throughput_ops_s(c=#{c})" => ops,
      "sweep_us.p99(c=#{c})" => pct(lat, 99)
    }
  end

  defp queue_sampler(parent, max) do
    receive do
      :stop -> send(parent, {:max_queue, max})
    after
      1 ->
        pids = [Process.whereis(WasmexHost) | WasmexPool.members()] |> Enum.filter(&is_pid/1)

        q =
          pids
          |> Enum.map(fn pid ->
            case Process.info(pid, :message_queue_len) do
              {:message_queue_len, len} -> len
              nil -> 0
            end
          end)
          |> Enum.max(fn -> 0 end)

        queue_sampler(parent, max(max, q))
    end
  end

  defp report(label, key, sorted) do
    IO.puts(
      "\n#{label}: n=#{length(sorted)} p50=#{pct(sorted, 50)} us p99=#{pct(sorted, 99)} us " <>
        "max=#{List.last(sorted)} us"
    )

    %{"#{key}.p50" => pct(sorted, 50), "#{key}.p99" => pct(sorted, 99)}
  end

  defp pct(sorted, p) do
    n = length(sorted)
    idx = (p / 100 * n) |> Float.ceil() |> trunc() |> max(1) |> min(n)
    Enum.at(sorted, idx - 1)
  end

  defp check(measured) do
    violations =
      for {key, bound} <- @bounds,
          value = Map.get(measured, key),
          not is_nil(value),
          violated?(key, value, bound) do
        "#{key}=#{value} violates bound #{bound}"
      end

    if violations == [] do
      IO.puts("\nbounds: all #{map_size(@bounds)} admitted bounds hold")
    else
      Enum.each(violations, &IO.puts("BOUND VIOLATED: " <> &1))
      System.halt(1)
    end
  end

  defp violated?("throughput" <> _, value, bound), do: value < bound
  defp violated?(_key, value, bound), do: value > bound
end

AshA2A.Bench.GraphLawThroughput.run(System.argv())
