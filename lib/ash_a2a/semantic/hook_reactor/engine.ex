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
      {:ok, %{"surface_sha256" => digest}} ->
        {:ok, %{module: AshGraphLaw, session: :pool, wasm_digest: digest}}

      {:ok, _} ->
        {:ok, %{module: AshGraphLaw, session: :pool, wasm_digest: nil}}

      {:error, %AshGraphLaw.Refusal{message: msg}} ->
        {:error, %{code: :hook_engine_unavailable, detail: msg}}

      {:error, reason} ->
        {:error, %{code: :hook_engine_unavailable, detail: inspect(reason)}}
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
      # Canonical evaluation using AshGraphLaw.call N3/denial or law step
      document = ntriples <> "\n" <> condition <> "\n"

      request = %{
        "op" => "validate_all",
        "document" => document,
        "schema" => "",
        "dialect" => "N3_DENIAL",
        "query" => "",
        "policy" => ""
      }

      case AshGraphLaw.call(request) do
        {:ok, %{"status" => "REFUSED"}} ->
          {:ok, true}

        {:ok, %{"status" => "ADMITTED"}} ->
          {:ok, false}

        {:ok, %{"dialects" => dialects}} when is_list(dialects) ->
          case Enum.find(dialects, &(is_map(&1) and &1["dialect"] == "N3_DENIAL")) do
            %{"status" => "REFUSED"} -> {:ok, true}
            %{"status" => "ADMITTED"} -> {:ok, false}
            other -> {:error, %{code: :hook_engine_unexpected, detail: inspect(other)}}
          end

        {:ok, response} ->
          # Check if any refusal is present in response
          if Map.get(response, "valid") == false or Map.get(response, "status") == "REFUSED" do
            {:ok, true}
          else
            {:ok, false}
          end

        {:error, %AshGraphLaw.Refusal{code: code, message: msg}} ->
          {:error, %{code: code, detail: msg}}

        other ->
          {:error, %{code: :hook_engine_unavailable, detail: inspect(other)}}
      end
    end
  end
end
