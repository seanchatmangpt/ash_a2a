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

  # The sentinel IRI carried by the rewritten denial rule; the engine's
  # `derived` text contains it iff the denial body has at least one binding.
  @condition_fired "urn:sa2a:hook:condition-fired/1"
  @comment_line ~r/^\s*#.*$/m
  @denial_rule ~r/\{([^{}]*)\}\s*=>\s*false\s*\./s

  @doc """
  Evaluates a condition over `ntriples` using `AshGraphLaw.hooks/3` (kh:
  conditions) or `AshGraphLaw.n3/2` (N3 denial conditions). Returns
  `{:ok, true | false}` or a typed refusal.
  """
  @spec matches?(runtime(), String.t(), String.t()) :: {:ok, boolean()} | {:error, map()}
  def matches?(_runtime, ntriples, condition)
      when is_binary(ntriples) and is_binary(condition) do
    # When condition is in kh: format, evaluate via AshGraphLaw.hooks/3
    # When condition is an N3 denial body, evaluate via AshGraphLaw.n3/2
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
      # The denial condition (one `{ BODY } => false .` rule plus `@prefix`
      # lines) is re-derived through `AshGraphLaw.n3/2`. The reasoner parses
      # `=> false` as an inference fuse, and that fuse is inert on the deployed
      # engine (witnessed: `{:ok, derived: ""}` for match, no-match and
      # empty-data alike, ground and bound premises alike), so the rule is
      # rewritten with a ground sentinel triple as the consequent instead. The
      # sentinel appears in the response's `derived` text iff the denial body
      # has at least one binding over the data — exactly the old N3_DENIAL
      # semantics (any binding => true). Fail-closed: a condition carrying zero
      # or several denial rules is refused, never silently judged.
      case denial_document(ntriples, condition) do
        {:ok, text} ->
          case AshGraphLaw.n3([text: text]) do
            {:ok, %AshGraphLaw.Result.N3{derived: derived}} ->
              {:ok, String.contains?(derived, "<" <> @condition_fired <> ">")}

            {:error, %AshGraphLaw.Refusal{message: msg}} ->
              {:error, %{code: :hook_engine_unavailable, detail: msg}}

            other ->
              {:error, %{code: :hook_engine_unexpected, detail: inspect(other)}}
          end

        {:error, refusal} ->
          {:error, refusal}
      end
    end
  end

  # Builds the N3 document for a denial condition: the data N-Triples, the
  # condition's `@prefix` declarations (comments dropped), and the denial rule
  # with its inert `=> false` consequent replaced by the ground sentinel
  # triple. The condition must carry exactly one denial rule — the same shape
  # `AshA2A.Semantic.HookReactor.Hook.condition_shape/2` enforces at admission.
  @spec denial_document(String.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  defp denial_document(ntriples, condition) do
    stripped = String.replace(condition, @comment_line, "")

    case Regex.scan(@denial_rule, stripped) do
      [[rule, body]] ->
        rewritten =
          "{ #{String.trim(body)} } => { <#{@condition_fired}> a <#{@condition_fired}> } ."

        {:ok, ntriples <> String.replace(stripped, rule, rewritten)}

      [] ->
        {:error,
         %{
           code: :hook_condition_invalid,
           detail: "N3 denial condition must be exactly one `{ BODY } => false .` rule"
         }}

      rules ->
        {:error,
         %{
           code: :hook_condition_invalid,
           detail:
             "N3 denial condition must be exactly one denial rule; found #{length(rules)}"
         }}
    end
  end
end
