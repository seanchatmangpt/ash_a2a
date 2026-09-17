defmodule AshA2A.Semantic.HookReactor.Engine do
  @moduledoc """
  Hook-condition evaluation through the real praxis-graphlaw engine, plus
  canonical delta identity.

  ## Why N3_DENIAL, not `run_hooks/2` (measured)

  The vendored engine (`praxis-graphlaw v26.7.5`, wasm sha256
  `187688d9...`) exports `run_hooks/2`, but that build never extracts hooks
  from its store: driven with `kh:Hook` packs in either the base or the event
  graph -- and with malformed input -- it returns
  `{"status":"ADMITTED","verdicts":[],"receipts":[],"schedule":[]}` every
  time (see `AshA2A.Semantic.FalsifierSuite`'s moduledoc for the root cause).
  Calling it would be theatre. Re-measured 2026-09-16 on a build of praxis
  HEAD `31f149d`: unchanged (root cause, inputs and outputs in
  `priv/graphlaw/defects/GL-DEFECT-001.json`; pinned against the vendored
  digest by `SA2A-ENGINE-001`/`-002`).

  The same build's `validate_all/5` N3_DENIAL dialect *does* evaluate rule
  bodies: `{ BODY } => false .` reports `"REFUSED"` iff BODY has at least one
  binding in the graph, `"ADMITTED"` iff it has none. That is a real,
  engine-native condition witness, so a hook condition is one denial body and
  `matches?/3` asks the engine whether it matches. Elixir decides nothing
  about the graph; it only reads the engine's verdict and fails closed on any
  status it does not recognize.

  ## Delta identity

  `canonical_delta/1` parses Turtle with RDF.ex's fail-closed reader and takes
  `RDF.Graph.canonical_hash/1` (RDFC-1.0: invariant under triple order, prefix
  labels and blank-node labels -- which the engine's own `graph_hash/1` is
  not). The engine is then fed the graph re-serialized as N-Triples.

  ## Sessions

  `open/1` starts an in-BEAM `AshA2A.GraphLaw.WasmexSession` by default (any
  `AshA2A.GraphLaw.Runtime` module may be passed as `:runtime_module`). A
  wasm-bindgen call is several host round trips against one linear memory,
  so calls on one session are serialized with a node-local `:global` lock.
  """

  alias AshA2A.GraphLaw.WasmexSession

  @type runtime :: %{module: module(), session: term(), wasm_digest: String.t() | nil}
  @type delta :: %{
          graph: RDF.Graph.t(),
          ntriples: String.t(),
          digest: String.t(),
          size: non_neg_integer()
        }

  @doc "Opens a real engine session."
  @spec open(keyword()) :: {:ok, runtime()} | {:error, map()}
  def open(opts \\ []) do
    module = Keyword.get(opts, :runtime_module, WasmexSession)

    case module.open(opts) do
      {:ok, %{session: session} = opened} ->
        {:ok, %{module: module, session: session, wasm_digest: Map.get(opened, :wasm_digest)}}

      {:error, reason} ->
        {:error, %{code: :hook_engine_unavailable, detail: reason}}
    end
  rescue
    error -> {:error, %{code: :hook_engine_unavailable, detail: Exception.message(error)}}
  end

  @doc "Closes an engine session."
  @spec close(runtime()) :: :ok
  def close(%{module: module, session: session}), do: module.close(session)

  @doc "Parses a Turtle delta into its canonical identity and N-Triples form."
  @spec canonical_delta(String.t()) :: {:ok, delta()} | {:error, map()}
  def canonical_delta(turtle) when is_binary(turtle) do
    case RDF.Turtle.read_string(turtle) do
      {:ok, %RDF.Graph{} = graph} -> {:ok, from_graph(graph)}
      {:error, reason} -> {:error, %{code: :hook_delta_unparseable, detail: inspect(reason)}}
    end
  rescue
    error -> {:error, %{code: :hook_delta_unparseable, detail: Exception.message(error)}}
  end

  def canonical_delta(other),
    do: {:error, %{code: :hook_delta_unparseable, detail: inspect(other)}}

  @doc false
  @spec from_graph(RDF.Graph.t()) :: delta()
  def from_graph(%RDF.Graph{} = graph) do
    %{
      graph: graph,
      ntriples: RDF.NTriples.write_string!(graph),
      digest: RDF.Graph.canonical_hash(graph),
      size: RDF.Graph.triple_count(graph)
    }
  end

  @doc """
  Asks the real engine whether the single denial body in `condition` has a
  binding in `ntriples`. `{:ok, true | false}` or a typed refusal.
  """
  @spec matches?(runtime(), String.t(), String.t()) :: {:ok, boolean()} | {:error, map()}
  def matches?(%{module: module, session: session}, ntriples, condition)
      when is_binary(ntriples) and is_binary(condition) do
    document = ntriples <> "\n" <> condition <> "\n"

    raw =
      with_session_lock(session, fn ->
        module.call(session, :validate_all, [document, "", "", "", ""])
      end)

    case raw do
      {:ok, text} when is_binary(text) ->
        with {:ok, report} <- decode(text), do: denial_verdict(report)

      other ->
        {:error, %{code: :hook_engine_unavailable, detail: inspect(other, limit: 10)}}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, %{"error" => message}} -> {:error, %{code: :hook_engine_unavailable, detail: message}}
      {:ok, %{} = report} -> {:ok, report}
      other -> {:error, %{code: :hook_engine_unexpected, detail: inspect(other)}}
    end
  end

  defp denial_verdict(%{"dialects" => dialects}) when is_list(dialects) do
    case Enum.find(dialects, &(is_map(&1) and &1["dialect"] == "N3_DENIAL")) do
      %{"status" => "REFUSED"} -> {:ok, true}
      %{"status" => "ADMITTED"} -> {:ok, false}
      other -> {:error, %{code: :hook_engine_unexpected, detail: inspect(other)}}
    end
  end

  defp denial_verdict(other),
    do: {:error, %{code: :hook_engine_unexpected, detail: inspect(other, limit: 5)}}

  defp with_session_lock(session, fun) do
    :global.trans({{__MODULE__, :erlang.phash2(session)}, self()}, fun, [node()], :infinity)
  end
end
