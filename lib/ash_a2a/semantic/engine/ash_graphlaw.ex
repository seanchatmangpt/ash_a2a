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
  def validate_shex(data, schema, shape_map, opts) do
    AshGraphLaw.shex([data: data, schema: schema, map: shape_map], opts)
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
          {:ok, AshGraphLaw.Result.Datalog.t()} | {:error, AshGraphLaw.Refusal.t()}
  def datalog_closure(data, rules, opts) do
    facts =
      cond do
        is_list(data) -> data
        is_binary(data) -> []
        true -> []
      end

    rule_list =
      cond do
        is_list(rules) -> rules
        is_map(rules) -> [rules]
        true -> []
      end

    AshGraphLaw.datalog([facts: facts, rules: rule_list], opts)
  end

  @doc "Evaluates Notation3 rules over data."
  @spec n3_closure(String.t() | map(), String.t() | nil) ::
          {:ok, AshGraphLaw.Result.N3.t()} | {:error, AshGraphLaw.Refusal.t()}
  def n3_closure(data, rules) do
    n3_closure(data, rules, [])
  end

  @doc "Evaluates Notation3 rules over data with options."
  @spec n3_closure(String.t() | map(), String.t() | nil, keyword()) ::
          {:ok, AshGraphLaw.Result.N3.t()} | {:error, AshGraphLaw.Refusal.t()}
  def n3_closure(data, rules, opts) do
    text =
      cond do
        is_binary(data) and (rules == "" or is_nil(rules)) ->
          data

        is_binary(data) and is_binary(rules) ->
          "#{data}\n#{rules}"

        is_map(data) and is_binary(data["text"]) ->
          data["text"]

        true ->
          to_string(data)
      end

    AshGraphLaw.n3([text: text], opts)
  end

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
