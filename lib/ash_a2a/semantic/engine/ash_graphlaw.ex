# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.Engine.AshGraphLaw do
  @moduledoc """
  Adapter bridging `ash_a2a`'s semantic engine requirements
  (`AshA2A.Semantic.Conformance`) to the `AshGraphLaw` membrane.

  Provides:
    * `validate_shex/3`: validates data against ShEx schema and shape map.
    * `validate_shacl/2`: validates data against SHACL shapes.
    * `query_sparql/2`: evaluates SPARQL query over data.
    * `datalog_closure/2`: evaluates Datalog rules over facts/data to a fixpoint.
    * `n3_closure/2`: evaluates Notation3 rules over data.

  Also provides engine metadata helpers `available?/0` and `version/0`.
  """

  @doc "Validates data against a ShEx schema and shape map."
  @spec validate_shex(String.t() | map(), String.t(), String.t()) ::
          {:ok, AshGraphLaw.Result.Shex.t()} | {:error, AshGraphLaw.Refusal.t()}
  def validate_shex(data, schema, shape_map) do
    validate_shex(data, schema, shape_map, [])
  end

  @doc "Validates data against a ShEx schema and shape map with options."
  @spec validate_shex(String.t() | map(), String.t(), String.t(), keyword()) ::
          {:ok, AshGraphLaw.Result.Shex.t()} | {:error, AshGraphLaw.Refusal.t()}
  def validate_shex(data, schema, shape_map, opts)
      when (is_binary(data) or is_map(data)) and is_binary(schema) and is_binary(shape_map) do
    AshGraphLaw.shex([data: data, schema: schema, map: shape_map], opts)
  end

  def validate_shex(data, schema, shape_map, _opts) do
    {:error,
     bad_input("validate_shex requires data (binary|map), schema and shape_map binaries", %{
       data: inspect(data, limit: 5),
       schema: inspect(schema, limit: 5),
       shape_map: inspect(shape_map, limit: 5)
     })}
  end

  @doc "Validates data against SHACL shapes graph."
  @spec validate_shacl(String.t() | map(), String.t()) ::
          {:ok, AshGraphLaw.Result.Shacl.t()} | {:error, AshGraphLaw.Refusal.t()}
  def validate_shacl(data, shapes) do
    validate_shacl(data, shapes, [])
  end

  @doc "Validates data against SHACL shapes graph with options."
  @spec validate_shacl(String.t() | map(), String.t(), keyword()) ::
          {:ok, AshGraphLaw.Result.Shacl.t()} | {:error, AshGraphLaw.Refusal.t()}
  def validate_shacl(data, shapes, opts) do
    AshGraphLaw.shacl([data: data, shapes: shapes], opts)
  end

  @doc "Evaluates a SPARQL query over data."
  @spec query_sparql(String.t() | map(), String.t()) ::
          {:ok, AshGraphLaw.Result.Sparql.t()} | {:error, AshGraphLaw.Refusal.t()}
  def query_sparql(data, query) do
    query_sparql(data, query, [])
  end

  @doc "Evaluates a SPARQL query over data with options."
  @spec query_sparql(String.t() | map(), String.t(), keyword()) ::
          {:ok, AshGraphLaw.Result.Sparql.t()} | {:error, AshGraphLaw.Refusal.t()}
  def query_sparql(data, query, opts) do
    AshGraphLaw.sparql([data: data, query: query], opts)
  end

  @doc "Evaluates Datalog rules over facts/data."
  @spec datalog_closure(term(), term()) ::
          {:ok, AshGraphLaw.Result.Datalog.t()} | {:error, AshGraphLaw.Refusal.t()}
  def datalog_closure(data, rules) do
    datalog_closure(data, rules, [])
  end

  @doc "Evaluates Datalog rules over facts/data with options."
  @spec datalog_closure(term(), term(), keyword()) ::
          {:ok, AshGraphLaw.Result.Datalog.t()}
          | {:error, AshGraphLaw.Refusal.t()}
          | {:error, bad_input()}
  def datalog_closure(facts, rules, opts) when is_list(facts) and is_list(rules) do
    AshGraphLaw.datalog([facts: facts, rules: rules], opts)
  end

  def datalog_closure(facts, %{} = rule, opts) when is_list(facts),
    do: datalog_closure(facts, [rule], opts)

  def datalog_closure(facts, rules, _opts) do
    {:error,
     bad_input(
       "datalog_closure/3 requires facts as a list of [s, p, o] triples and rules as a list " <>
         "(or one map) of rule objects",
       %{facts: inspect(facts, limit: 5), rules: inspect(rules, limit: 5)}
     )}
  end

  @doc "Evaluates Notation3 rules over data."
  @spec n3_closure(String.t() | map(), String.t() | nil) ::
          {:ok, AshGraphLaw.Result.N3.t()}
          | {:error, AshGraphLaw.Refusal.t()}
          | {:error, bad_input()}
  def n3_closure(data, rules) do
    n3_closure(data, rules, [])
  end

  @doc "Evaluates Notation3 rules over data with options."
  @spec n3_closure(String.t() | map(), String.t() | nil, keyword()) ::
          {:ok, AshGraphLaw.Result.N3.t()}
          | {:error, AshGraphLaw.Refusal.t()}
          | {:error, bad_input()}
  def n3_closure(data, rules, opts) do
    case n3_text(data, rules) do
      {:ok, text} -> AshGraphLaw.n3([text: text], opts)
      {:error, _} = error -> error
    end
  end

  defp n3_text(data, rules) when is_binary(data) and rules in [nil, ""], do: {:ok, data}

  defp n3_text(data, rules) when is_binary(data) and is_binary(rules),
    do: {:ok, data <> "\n" <> rules}

  defp n3_text(%{"text" => text}, rules) when is_binary(text) and rules in [nil, ""],
    do: {:ok, text}

  defp n3_text(%{"text" => text}, rules) when is_binary(text) and is_binary(rules),
    do: {:ok, text <> "\n" <> rules}

  defp n3_text(data, rules) do
    {:error,
     bad_input(
       "n3_closure requires data as a binary or a %{\"text\" => binary} map and rules as " <>
         "a binary or nil",
       %{data: inspect(data, limit: 5), rules: inspect(rules, limit: 5)}
     )}
  end

  @typedoc "Typed refusal for input the adapter will not coerce."
  @type bad_input :: %{code: :engine_bad_input, detail: String.t(), got: map()}

  defp bad_input(detail, got), do: %{code: :engine_bad_input, detail: detail, got: got}

  @probe_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n"

  @doc """
  Runs one tiny real operation through the engine for `function`/`arity` and
  reports whether the engine actually answered. Used by
  `AshA2A.Semantic.Conformance.engine_capability/2` so `:met` means the engine
  ran the capability, not merely that this module exports the function.
  """
  @spec probe(atom(), non_neg_integer()) :: :ok | {:error, term()}
  def probe(function, arity) do
    function
    |> probe_call(arity)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp probe_call(:validate_shex, 3),
    do:
      validate_shex(
        @probe_ttl,
        "PREFIX ex: <http://example.org/>\n<http://example.org/S> { ex:p . }",
        "<http://example.org/a>@<http://example.org/S>"
      )

  defp probe_call(:validate_shacl, 2),
    do:
      validate_shacl(
        @probe_ttl,
        "@prefix sh: <http://www.w3.org/ns/shacl#> .\n" <>
          "@prefix ex: <http://example.org/> .\n" <>
          "ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 1 ] ."
      )

  defp probe_call(:query_sparql, 2),
    do: query_sparql(@probe_ttl, "SELECT ?o WHERE { ?s <http://example.org/p> ?o }")

  defp probe_call(:datalog_closure, 2),
    do:
      datalog_closure(
        [["a", "p", "b"]],
        [%{"head" => ["?x", "q", "?y"], "body" => [["?x", "p", "?y"]]}]
      )

  defp probe_call(:n3_closure, 2),
    do:
      n3_closure(
        "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\n" <>
          "{ ?x ex:p ?y } => { ?y ex:q ?x } .\n",
        nil
      )

  defp probe_call(function, arity), do: {:error, {:no_probe, function, arity}}

  @doc "Checks if the AshGraphLaw host engine is reachable and loaded."
  @spec available?() :: boolean()
  def available? do
    AshGraphLaw.capabilities()
    |> case do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Returns the version of the underlying GraphLaw engine."
  @spec version() :: {:ok, String.t()}
  def version do
    {:ok, AshGraphLaw.graphlaw_release()}
  end
end
