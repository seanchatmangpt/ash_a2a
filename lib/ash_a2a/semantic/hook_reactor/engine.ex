# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.HookReactor.Engine do
  @moduledoc """
  Hook evaluation through the canonical `AshGraphLaw` library and underlying
  `graphlaw` engine.

  `ash_a2a` does not possess its own hook engine; all hook parsing, condition
  matching, and materialization flow directly through `AshGraphLaw`.
  """

  @type runtime :: %{module: module(), session: term(), wasm_digest: String.t() | nil}
  @type delta :: %{
          graph: RDF.Graph.t(),
          ntriples: String.t(),
          digest: String.t(),
          size: non_neg_integer()
        }

  @doc "Opens an AshGraphLaw engine session / pool reference."
  @spec open(keyword()) :: {:ok, runtime()} | {:error, map()}
  def open(opts \\ []) do
    case AshGraphLaw.capabilities(opts) do
      {:ok, %{"surface_blake3" => digest}} ->
        {:ok, %{module: AshGraphLaw, session: :pool, wasm_digest: digest}}

      {:ok, _} ->
        {:ok, %{module: AshGraphLaw, session: :pool, wasm_digest: nil}}

      {:error, %AshGraphLaw.Refusal{message: msg}} ->
        {:error, %{code: :hook_engine_unavailable, detail: msg}}

      # (the old bare `{:error, reason}` catch-all was dead: every `{:error, _}`
      # `AshGraphLaw.capabilities/1` can return is a `%AshGraphLaw.Refusal{}`)
    end
  rescue
    error -> {:error, %{code: :hook_engine_unavailable, detail: Exception.message(error)}}
  end

  @doc "Closes an engine session."
  @spec close(runtime()) :: :ok
  def close(_runtime), do: :ok

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
  Evaluates a condition over `ntriples` using `AshGraphLaw.hooks/3`.
  Returns `{:ok, true | false}` or a typed refusal.
  """
  @spec matches?(runtime(), String.t(), String.t()) :: {:ok, boolean()} | {:error, map()}
  def matches?(_runtime, ntriples, condition)
      when is_binary(ntriples) and is_binary(condition) do
    # When condition is in kh: format, evaluate via AshGraphLaw.hooks/3
    # When condition is an N3 denial body, wrap or evaluate via AshGraphLaw.call/2
    if String.contains?(condition, "kh:") or String.contains?(condition, "SELECT") do
      pack = %{"dialect" => "turtle", "text" => condition}
      data = %{"dialect" => "ntriples", "text" => ntriples}

      case AshGraphLaw.hooks(data, pack) do
        {:ok, %{"firings" => firings}} ->
          {:ok, length(firings) > 0}

        {:error, %AshGraphLaw.Refusal{message: msg}} ->
          {:error, %{code: :hook_engine_unavailable, detail: msg}}

        other ->
          {:error, %{code: :hook_engine_unexpected, detail: inspect(other)}}
      end
    else
      # ABI v26.10.28 retired the legacy `validate_all` / `N3_DENIAL` op pair.
      # The N3-denial route must be re-derived through AshGraphLaw.n3/2 (parse
      # the condition as N3 over the projected data, derive admitted/refused).
      # Until that lands this arm fails closed with a typed error — it can
      # never silently report a denial verdict.
      {:error,
       %{
         code: :hook_n3_denial_unported,
         detail:
           "the legacy validate_all/N3_DENIAL op pair was removed in graphlaw " <>
             "v26.10.28; re-route this condition through AshGraphLaw.n3/2"
       }}
    end
  end
end
