defmodule AshA2A.Chicago.Bench.B7CrossRuntime do
  @moduledoc """
  RFC-SA2A-002 §91 benchmark `SA2A-B7` -- cross-runtime portable semantic
  execution, extracted into the standalone bench interface from the real
  measurement already embedded in `AshA2A.Chicago.Courts.CrossRuntimePortability`
  (`SA2A-XRUNTIME-010`, its falsifier `fid(10)`).

  Exercises the exact same real judged path the court measures -- no new
  operation is invented:

    * `AshA2A.SA2A.Conformance.run/1` (`runtime_a:`, `runtime_b:`,
      `corpus_dir:`) is the boundary under measurement: one content-addressed
      GraphLaw wasm artifact (`priv/graphlaw/praxis_graphlaw.wasm`) judged by
      two genuinely heterogeneous real hosts over a real fixture corpus
      (`AshA2A.Chicago.Fixtures.CrossRuntime`).
    * `AshA2A.RuntimeIdentity.Execution.meter/2` is the real resource meter
      wrapped around it (wall time, OS-process RSS, BEAM-engine memory).
    * The judged receipt is persisted to disk and read back before any
      figure is derived from it -- the same "never trust the in-memory
      return value" discipline the court itself applies.

  Two host pairs, same as the court: BEAM/Wasmex (in-BEAM Wasmtime NIF) x
  Node/StandaloneJS (V8 subprocess), always; Node/StandaloneJS x
  Native/graphlaw_host (Wasmtime binary), only when the native runtime is
  available on this machine (§126 -- unavailable makes that case BLOCKED-shaped
  in the body, never fabricated).

  The corpus (both pairs' fixture directories) is built once, before
  `Bench.measure/2`'s warmup/measured loop -- the same "build fixtures once,
  measure the repeated call" shape as `AshA2A.Chicago.Bench.B1Admission`. Each
  iteration re-runs the real judged call and real meter fresh; only the corpus
  on disk is reused.

  Defaults to 1 measured iteration and 0 warmup (`iterations: 1, warmup: 0`)
  unless the caller overrides: a full judged run spawns a V8 subprocess plus
  the in-BEAM Wasmtime NIF (and, when built, the native Wasmtime binary) and
  is not a hot-path microbenchmark.
  """

  alias AshA2A.Chicago.Bench
  alias AshA2A.Chicago.Fixtures.CrossRuntime, as: Fx
  alias AshA2A.GraphLaw.{RuntimeB, WasmexSession, WasmtimeRuntime}
  alias AshA2A.RuntimeIdentity.Execution
  alias AshA2A.SA2A.Conformance

  @id "SA2A-B7"

  @admit "v001_minimal_admit"
  @shacl_refusal "v004_shacl_min_count_violation"
  @shex_refusal "v009_shex_violation"
  @native_subset [@admit, @shacl_refusal, @shex_refusal]

  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Runs the benchmark. Returns `{:ok, body}` or `{:blocked, detail}` when the
  base host pair (BEAM/Wasmex, Node/StandaloneJS) is not runnable on this
  machine (never a fake engine).

  Options: `:iterations` (default 1), `:warmup` (default 0).
  """
  @spec run(keyword()) :: {:ok, map()} | {:blocked, String.t()}
  def run(opts \\ []) do
    case availability([WasmexSession, RuntimeB]) do
      :ok -> {:ok, measure(opts)}
      {:error, detail} -> {:blocked, detail}
    end
  end

  @spec availability([module()]) :: :ok | {:error, String.t()}
  defp availability(runtimes) do
    Enum.find_value(runtimes, :ok, fn runtime ->
      case runtime.available?([]) do
        :ok -> nil
        {:error, reason} -> {:error, "#{inspect(runtime)} is unavailable: #{inspect(reason)}"}
      end
    end)
  end

  defp measure(opts) do
    root = fresh_root()
    native? = availability([WasmtimeRuntime]) == :ok

    pairs =
      [{"wasmex_x_runtime_b", WasmexSession, RuntimeB, :all}] ++
        if native?,
          do: [{"runtime_b_x_wasmtime", RuntimeB, WasmtimeRuntime, @native_subset}],
          else: []

    corpora =
      Map.new(pairs, fn {name, _a, _b, vector_ids} ->
        {name, Fx.corpus!(Path.join(root, "corpus-#{name}"), vector_ids, [:malformed_turtle])}
      end)

    {:ok, collector} = Agent.start_link(fn -> [] end)

    run_opts = opts |> Keyword.put_new(:iterations, 1) |> Keyword.put_new(:warmup, 0)

    measured =
      Bench.measure(
        fn phase, i -> Enum.map(pairs, &pair_sample(&1, corpora, root, phase, i, collector)) end,
        run_opts
      )

    raw = collector |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(collector)

    measured_raw = Enum.filter(raw, &(&1["phase"] == :measured))

    Map.merge(measured, %{
      "benchmark" => "B7 cross-runtime portable semantic execution",
      "rfc_sections" => ["§76", "§91", "§100", "§125", "§126"],
      "sut" => %{
        "boundary" => "AshA2A.SA2A.Conformance.run/1",
        "meter" => "AshA2A.RuntimeIdentity.Execution.meter/2",
        "hosts" =>
          Enum.map(pairs, fn {name, a, b, _} ->
            %{"case" => name, "hosts" => [inspect(a), inspect(b)]}
          end)
      },
      "native_runtime_available" => native?,
      "pairs" => raw,
      "artifact_digests" =>
        measured_raw |> Enum.map(& &1["artifact_digest"]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      "highlights" => %{
        "judged_pair_count" => Enum.count(measured_raw, & &1["judged"]),
        "not_judged_pair_count" => Enum.count(measured_raw, &(not &1["judged"])),
        "p50_wall_us" => measured["latency_us"]["p50"],
        "p99_wall_us" => measured["latency_us"]["p99"]
      }
    })
  end

  defp pair_sample({name, runtime_a, runtime_b, vector_ids}, corpora, root, phase, i, collector) do
    corpus = Map.fetch!(corpora, name)

    {result, meter} =
      Execution.meter(fn ->
        Conformance.run(runtime_a: runtime_a, runtime_b: runtime_b, corpus_dir: corpus)
      end)

    receipt =
      persist_receipt(
        Path.join([root, "receipts", "#{name}-#{phase}-#{i}.json"]),
        result
      )

    detail =
      Map.merge(pair_detail(receipt, meter, result, vector_ids), %{
        "case" => name,
        "phase" => phase,
        "iteration" => i
      })

    Agent.update(collector, &[detail | &1])

    %{
      case: name,
      duration_us: meter["wall_us"],
      outcome: if(detail["judged"], do: "judged", else: "not_judged"),
      phases: %{"wall_us" => meter["wall_us"]},
      invariant: invariant(detail)
    }
  end

  defp pair_detail(nil, meter, result, _vector_ids),
    do: %{"judged" => false, "not_judged" => summarize(result), "wall_us" => meter["wall_us"]}

  defp pair_detail(receipt, meter, _result, vector_ids) do
    pairs = vector_pairs(receipt)

    %{
      "judged" => true,
      "artifact_digest" => receipt["wasm_digest"],
      "result" => receipt["result"],
      "fixture_count" => length(pairs),
      "expected_fixture_count" => length(vector_ids_with_negative(vector_ids)),
      "admission_equivalence_count" => Enum.count(pairs, &agrees?/1),
      "post_state_equivalence_count" => Enum.count(pairs, &post_state_equal?/1),
      "input_identity_equivalence_count" =>
        Enum.count(pairs, fn {va, vb} = pair ->
          computed?(pair) and va["input_graph_hash"] == vb["input_graph_hash"] and
            va["input_graph_hash"] == va["input_graph_hash_repeat"] and
            vb["input_graph_hash"] == vb["input_graph_hash_repeat"]
        end),
      "disagreements" =>
        pairs
        |> Enum.reject(&(agrees?(&1) and post_state_equal?(&1)))
        |> Enum.map(&elem(&1, 0)["vector"]),
      "hosts" => host_summaries(receipt, meter),
      "wall_us" => meter["wall_us"]
    }
  end

  defp vector_ids_with_negative(:all), do: [:all]
  defp vector_ids_with_negative(ids) when is_list(ids), do: ids ++ [:malformed_turtle]

  defp host_summaries(receipt, meter) do
    for side <- ["runtime_a", "runtime_b"] do
      section = receipt[side] || %{}
      executed = section["executed_identity"] || []
      os_shas = for %{"kind" => "os_process", "executable_sha256" => sha} <- executed, do: sha
      modules = for %{"kind" => "beam_process", "engine_module" => m} <- executed, do: m

      %{
        "side" => side,
        "host" => section["host"],
        "engine" => section["engine"],
        "latency_us" => section["observe_us"],
        "memory" => %{
          "os_processes" =>
            Enum.filter(meter["os_processes"] || [], &(&1["executable_sha256"] in os_shas)),
          "beam_engines" =>
            Enum.filter(meter["beam_engines"] || [], &(&1["engine_module"] in modules))
        }
      }
    end
  end

  defp invariant(%{"judged" => false} = detail),
    do: {:error, "not judged: #{inspect(detail["not_judged"])}"}

  defp invariant(%{"disagreements" => []}), do: :ok

  defp invariant(%{"disagreements" => disagreements}),
    do:
      {:error,
       "host pair disagreed on #{length(disagreements)} vector(s): #{inspect(disagreements)}"}

  defp persist_receipt(path, {_tag, %{"profile" => _} = receipt}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(receipt))
    path |> File.read!() |> JSON.decode!()
  end

  defp persist_receipt(_path, _not_judged), do: nil

  defp vector_pairs(receipt),
    do: Enum.zip(receipt["runtime_a"]["vectors"] || [], receipt["runtime_b"]["vectors"] || [])

  defp computed?({va, vb}), do: va["computed"] == true and vb["computed"] == true

  defp agrees?({va, vb} = pair) do
    computed?(pair) and va["vector"] == vb["vector"] and va["admission"] == vb["admission"] and
      va["refusal_reason"] == vb["refusal_reason"] and va["state_trace"] == vb["state_trace"]
  end

  defp post_state_equal?({va, vb} = pair) do
    computed?(pair) and is_binary(va["output_graph_hash"]) and
      va["output_graph_hash"] == vb["output_graph_hash"] and
      va["post_state_identity"] == vb["post_state_identity"]
  end

  defp summarize({tag, %{"result" => result}}), do: %{"tag" => inspect(tag), "result" => result}

  defp summarize({tag, %{code: code} = reason}),
    do: %{"tag" => inspect(tag), "code" => code, "reason" => inspect(reason, limit: 10)}

  defp summarize(other), do: %{"raw" => inspect(other, limit: 10)}

  defp fresh_root do
    Path.join([
      System.tmp_dir!(),
      "ash_a2a_bench",
      @id,
      Integer.to_string(System.unique_integer([:positive]))
    ])
  end
end
