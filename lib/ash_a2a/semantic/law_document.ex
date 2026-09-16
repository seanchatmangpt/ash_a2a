defmodule AshA2A.Semantic.LawDocument do
  @moduledoc """
  Non-vacuity analysis of the *law* documents an admission candidate is judged
  under: the SHACL shapes graph, the ShExJ schema and shape map, the OWL
  profile, and the N3 falsifier set.

  ## Why this module exists (RFC S43)

  `AshA2A.Semantic.AdmissionPipeline` used to guard each law-bearing stage with
  a blankness test: if the document string was not blank, the stage was allowed
  to read the engine's verdict as a determination. Three real, reproduced
  defects followed from that, all of the same shape --
  `Unknown(Valid(x)) => Admitted(x)`:

    * A `profile_ttl` of `"@@@ not turtle at all ;;; <<<"` is not blank, so the
      profile stage ran. The engine parsed zero profile axioms out of it and
      reported OWL_RL `ADMITTED`, and the pipeline read that as
      "the profile was checked and it held". Measured: that run's
      `profile_hash` came back as
      `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262` --
      the BLAKE3 digest of the **empty string** -- while a real profile hashes
      to `f9a3710a9240d0040bba0cef77e572c0382b0eae3057a811648de617d43f9d58`.
    * A `falsifiers` document of `"#"` (one comment, zero rules) is not blank,
      so the falsifier stage ran. Zero rules produce zero violations, the
      engine reported N3_DENIAL `ADMITTED`, and a graph that the real falsifier
      set **positively refuses** (`ex:b a ex:Forbidden`) was admitted instead.
    * A `shacl_shapes` document of `"#"` behaves the same way: zero shapes
      target nothing, the engine reports `Report: 0 violations`, and a graph
      the real shapes refuse is admitted.

  Running zero checks and finding zero failures determines nothing. This module
  is where "the document actually asserts something checkable" becomes a real,
  parsed, counted predicate instead of a string-emptiness test.

  ## What is real here, and what is delegated

  This module **does not validate anything**. It does not evaluate SHACL, does
  not evaluate ShEx, does not run rules, and does not decide conformance --
  every one of those determinations still belongs to the real GraphLaw engine
  through `AshA2A.GraphLaw.Wasm`. What it does is parse a law document well
  enough to answer one question: *how many checkable obligations does this
  document declare?* Zero is a refusal.

    * Turtle-shaped law (SHACL shapes, OWL profile) is parsed by **RDF.ex**
      (`RDF.Turtle.read_string/1`), which fails closed on malformed input --
      measured: `{:error, "Turtle scanner error on line 1: {:illegal, '@@'}"}`
      for the garbage above, where the wasm's `graph_hash/1` silently returns
      the empty-graph digest instead.
    * ShExJ law is parsed as JSON, because that is what it is.
    * N3 falsifier law is scanned for implication statements. RDF.ex's Turtle
      reader cannot parse N3 rules (measured:
      `"Turtle scanner error on line 2: {:illegal, '?'}"` on the real falsifier
      fixture), and the wasm's `graph_hash/1` returns the empty-graph digest
      for a *real* rule document just as it does for `"#"` -- so neither of the
      two available parsers can count rules, and `n3_rule_count/1` recognises
      implication statements lexically. It is a statement recogniser, not a
      rule engine: it never decides whether a rule fires.
  """

  @sh "http://www.w3.org/ns/shacl#"
  @owl "http://www.w3.org/2002/07/owl#"
  @rdfs "http://www.w3.org/2000/01/rdf-schema#"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  @shape_types [@sh <> "NodeShape", @sh <> "PropertyShape"]
  @target_predicates [
    @sh <> "targetClass",
    @sh <> "targetNode",
    @sh <> "targetSubjectsOf",
    @sh <> "targetObjectsOf"
  ]

  @typedoc "Why a law document could not be read as declaring obligations."
  @type failure :: %{required(:code) => atom(), optional(:reason) => String.t()}

  @doc """
  Parses a Turtle law document with RDF.ex, failing closed on malformed input.

      iex> {:ok, graph} = AshA2A.Semantic.LawDocument.turtle_graph("<a:a> <a:b> <a:c> .")
      iex> RDF.Graph.triple_count(graph)
      1

      iex> {:error, failure} = AshA2A.Semantic.LawDocument.turtle_graph("@@@ nope")
      iex> failure.code
      :turtle_not_parseable
  """
  @spec turtle_graph(String.t()) :: {:ok, RDF.Graph.t()} | {:error, failure()}
  def turtle_graph(document) when is_binary(document) do
    case RDF.Turtle.read_string(document) do
      {:ok, %RDF.Graph{} = graph} ->
        {:ok, graph}

      {:error, reason} ->
        {:error, %{code: :turtle_not_parseable, reason: reason_text(reason)}}
    end
  rescue
    error -> {:error, %{code: :turtle_not_parseable, reason: Exception.message(error)}}
  end

  @doc """
  Number of distinct SHACL shapes a shapes document actually declares.

  A shape is a subject that is typed `sh:NodeShape`/`sh:PropertyShape` or that
  carries one of the four `sh:target*` predicates. A document declaring none
  targets nothing, so it can only ever report zero violations.

      iex> AshA2A.Semantic.LawDocument.shacl_shape_count("#")
      {:ok, 0}
  """
  @spec shacl_shape_count(String.t()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def shacl_shape_count(document) when is_binary(document) do
    with {:ok, graph} <- turtle_graph(document) do
      count =
        graph
        |> RDF.Graph.triples()
        |> Enum.filter(&shape_declaration?/1)
        |> Enum.map(fn {subject, _p, _o} -> to_string(subject) end)
        |> Enum.uniq()
        |> length()

      {:ok, count}
    end
  end

  @doc """
  Number of OWL/RDFS axioms an OWL profile document actually declares.

  A profile document that parses but carries no OWL or RDFS vocabulary
  constrains nothing, so an OWL_RL pass over it is vacuous.

      iex> AshA2A.Semantic.LawDocument.owl_axiom_count(
      ...>   "<http://example.org/Goal> a <http://www.w3.org/2002/07/owl#Class> ."
      ...> )
      {:ok, 1}
  """
  @spec owl_axiom_count(String.t()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def owl_axiom_count(document) when is_binary(document) do
    with {:ok, graph} <- turtle_graph(document) do
      count = graph |> RDF.Graph.triples() |> Enum.count(&owl_axiom?/1)
      {:ok, count}
    end
  end

  @doc """
  Number of shapes a ShExJ schema declares, failing closed on non-JSON input.

      iex> AshA2A.Semantic.LawDocument.shex_shape_count(~s({"shapes":[]}))
      {:ok, 0}

      iex> {:error, failure} = AshA2A.Semantic.LawDocument.shex_shape_count("#")
      iex> failure.code
      :shex_schema_not_json
  """
  @spec shex_shape_count(String.t()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def shex_shape_count(document) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, %{"shapes" => shapes}} when is_list(shapes) ->
        {:ok, length(shapes)}

      {:ok, decoded} when is_map(decoded) ->
        {:error, %{code: :shex_schema_has_no_shapes_key}}

      {:ok, _other} ->
        {:error, %{code: :shex_schema_not_an_object}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, %{code: :shex_schema_not_json, reason: Exception.message(error)}}
    end
  end

  @doc """
  Number of focus-node/shape pairs a ShEx shape map declares.

      iex> AshA2A.Semantic.LawDocument.shex_shape_map_count(~s([["a","b"]]))
      {:ok, 1}
  """
  @spec shex_shape_map_count(String.t()) :: {:ok, non_neg_integer()} | {:error, failure()}
  def shex_shape_map_count(document) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, pairs} when is_list(pairs) ->
        {:ok, Enum.count(pairs, &valid_shape_map_entry?/1)}

      {:ok, _other} ->
        {:error, %{code: :shex_shape_map_not_a_list}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, %{code: :shex_shape_map_not_json, reason: Exception.message(error)}}
    end
  end

  @doc """
  Number of N3 implication statements a falsifier document declares.

  Counts `=>` and `<=` tokens, and the `log:implies` predicate, that appear at
  statement level -- never inside a comment, an IRI, or a string literal. This
  is a statement recogniser: it answers "does this document declare any rule at
  all", which is precisely the predicate the pipeline needs and precisely the
  predicate neither available parser can supply. Whether a declared rule fires
  is decided by GraphLaw's real N3_DENIAL dialect, not here.

      iex> AshA2A.Semantic.LawDocument.n3_rule_count("#")
      0

      iex> AshA2A.Semantic.LawDocument.n3_rule_count("{ ?s a <a:X> } => false .")
      1

      iex> AshA2A.Semantic.LawDocument.n3_rule_count(~s(<a:s> <a:p> "a => b" .))
      0
  """
  @spec n3_rule_count(String.t()) :: non_neg_integer()
  def n3_rule_count(document) when is_binary(document) do
    scan_n3(document, :normal, 0)
  end

  # --- SHACL / OWL triple predicates -------------------------------------

  defp shape_declaration?({_s, p, o}) do
    predicate = to_string(p)

    (predicate == @rdf_type and to_string(o) in @shape_types) or predicate in @target_predicates
  end

  defp owl_axiom?({_s, p, o}) do
    predicate = to_string(p)

    String.starts_with?(predicate, @owl) or String.starts_with?(predicate, @rdfs) or
      (predicate == @rdf_type and
         (String.starts_with?(to_string(o), @owl) or String.starts_with?(to_string(o), @rdfs)))
  end

  defp valid_shape_map_entry?([focus, shape]) when is_binary(focus) and is_binary(shape), do: true
  defp valid_shape_map_entry?(%{"node" => _, "shape" => _}), do: true
  defp valid_shape_map_entry?(_other), do: false

  # --- N3 implication-statement recogniser --------------------------------
  #
  # A real character-state scanner rather than a regex, because `=>` inside a
  # comment, inside an IRI, or inside a string literal is not a rule, and a
  # regex cannot tell those apart. States: :normal, :comment, :iri, :quote
  # (short string), :long_quote (triple-quoted string).

  defp scan_n3(<<>>, _state, count), do: count

  defp scan_n3(<<?#, rest::binary>>, :normal, count), do: scan_n3(rest, :comment, count)

  defp scan_n3(<<?\n, rest::binary>>, :comment, count), do: scan_n3(rest, :normal, count)
  defp scan_n3(<<_c::utf8, rest::binary>>, :comment, count), do: scan_n3(rest, :comment, count)

  defp scan_n3(<<"=>", rest::binary>>, :normal, count), do: scan_n3(rest, :normal, count + 1)
  defp scan_n3(<<"<=", rest::binary>>, :normal, count), do: scan_n3(rest, :normal, count + 1)

  defp scan_n3(<<"log:implies", rest::binary>>, :normal, count),
    do: scan_n3(rest, :normal, count + 1)

  defp scan_n3(<<?<, rest::binary>>, :normal, count), do: scan_n3(rest, :iri, count)
  defp scan_n3(<<?>, rest::binary>>, :iri, count), do: scan_n3(rest, :normal, count)
  defp scan_n3(<<_c::utf8, rest::binary>>, :iri, count), do: scan_n3(rest, :iri, count)

  defp scan_n3(<<"\"\"\"", rest::binary>>, :normal, count), do: scan_n3(rest, :long_quote, count)
  defp scan_n3(<<"\"\"\"", rest::binary>>, :long_quote, count), do: scan_n3(rest, :normal, count)

  defp scan_n3(<<?\\, _c::utf8, rest::binary>>, :long_quote, count),
    do: scan_n3(rest, :long_quote, count)

  defp scan_n3(<<_c::utf8, rest::binary>>, :long_quote, count),
    do: scan_n3(rest, :long_quote, count)

  defp scan_n3(<<?", rest::binary>>, :normal, count), do: scan_n3(rest, :quote, count)
  defp scan_n3(<<?', rest::binary>>, :normal, count), do: scan_n3(rest, :single_quote, count)

  defp scan_n3(<<?\\, _c::utf8, rest::binary>>, :quote, count), do: scan_n3(rest, :quote, count)
  defp scan_n3(<<?", rest::binary>>, :quote, count), do: scan_n3(rest, :normal, count)
  defp scan_n3(<<_c::utf8, rest::binary>>, :quote, count), do: scan_n3(rest, :quote, count)

  defp scan_n3(<<?\\, _c::utf8, rest::binary>>, :single_quote, count),
    do: scan_n3(rest, :single_quote, count)

  defp scan_n3(<<?', rest::binary>>, :single_quote, count), do: scan_n3(rest, :normal, count)

  defp scan_n3(<<_c::utf8, rest::binary>>, :single_quote, count),
    do: scan_n3(rest, :single_quote, count)

  defp scan_n3(<<_c::utf8, rest::binary>>, :normal, count), do: scan_n3(rest, :normal, count)

  # A lone malformed byte cannot make a rule appear; consume it and continue.
  defp scan_n3(<<_c, rest::binary>>, state, count), do: scan_n3(rest, state, count)

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
