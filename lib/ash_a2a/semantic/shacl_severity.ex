defmodule AshA2A.Semantic.ShaclSeverity do
  @moduledoc """
  Severity partition of a SHACL shapes graph, so the admission pipeline can
  honour RFC-SA2A-001 S15 on an engine that does not expose result severity:

  > Conformance-critical violations MUST fail closed. Warnings MUST NOT
  > override a failing MUST-level invariant.

  ## Why a partition

  The pinned `praxis-graphlaw` wasm follows SHACL Core literally: its SHACL
  dialect reports `REFUSED` whenever *any* validation result exists, whatever
  its `sh:severity`, and it reports only `"Report: N violations"` -- no
  per-result severity. Measured on the Gate 2 world law
  (`AshA2A.Chicago.Fixtures.ShexShaclAdmission`): a graph whose only result
  comes from a `sh:Warning` shape is `REFUSED` exactly like a real
  `sh:Violation`. Read directly, that conflates the two and refuses every
  warning-only graph (found by the `SA2A-SHACL` court, RFC-SA2A-002 §46/§100).

  `violations_only/1` removes every `sh:Warning`/`sh:Info` shape from the
  shapes graph. The engine then runs twice -- full law and violations-only
  law -- and the S15 verdict is set difference over two real engine runs, the
  same derivation `priv/sa2a_conformance/shapes.violations.shacl.ttl` encodes
  by hand for the conformance corpus:

      violations-only REFUSED                -> a real Violation: refuse
      violations-only ADMITTED, full REFUSED -> warning-only: admit
      full ADMITTED                          -> clean: admit

  Measured agreement with the hand-partitioned corpus file on `base`,
  `shacl_warning_only`, `shacl_violation_and_warning`, `shacl_violation` and
  `unadmitted_predicate`.

  ## Fail-closed: a partition that could change a Violation's meaning is refused

  This module never validates. It only rewrites law, and a rewrite that could
  weaken a MUST-level shape is refused with `:shacl_severity_not_partitionable`
  (the pipeline then keeps full-report semantics, i.e. refuses):

    * a non-Violation shape referenced by anything other than `sh:property`
      (`sh:node`, `sh:not`, `sh:qualifiedValueShape`, a logical list) -- a
      Violation shape's meaning depends on it;
    * a non-Violation shape that itself carries nested shapes (`sh:property`,
      `sh:node`, `sh:and`, `sh:or`, `sh:xone`, `sh:not`,
      `sh:qualifiedValueShape`) -- nested shapes have their own severity;
    * a non-Violation property shape hanging off an `sh:closed` node shape --
      removing its path would change the closed predicate set.

  Only exactly `sh:Warning` and `sh:Info` are non-Violation. Any other severity
  value, custom IRIs included, is treated as a Violation.
  """

  @sh "http://www.w3.org/ns/shacl#"
  @non_violation [@sh <> "Warning", @sh <> "Info"]
  @nesting ~w(property node and or xone not qualifiedValueShape)a |> Enum.map(&"#{@sh}#{&1}")

  @typedoc "Why a shapes graph could not be partitioned."
  @type failure :: %{required(:code) => atom(), optional(atom()) => term()}

  @doc """
  Returns `{:ok, :no_non_violation_shapes}` when every shape is Violation
  severity (nothing to partition), `{:ok, %{violations_only: turtle, removed:
  n}}` with the Violation-only law, or `{:error, failure}`.

      iex> AshA2A.Semantic.ShaclSeverity.violations_only(
      ...>   "@prefix sh: <http://www.w3.org/ns/shacl#> . <a:S> a sh:NodeShape ; sh:targetClass <a:C> ."
      ...> )
      {:ok, :no_non_violation_shapes}
  """
  @spec violations_only(String.t()) ::
          {:ok, :no_non_violation_shapes | %{violations_only: String.t(), removed: pos_integer()}}
          | {:error, failure()}
  def violations_only(shapes) when is_binary(shapes) do
    with {:ok, graph} <- AshA2A.Semantic.LawDocument.turtle_graph(shapes) do
      triples = RDF.Graph.triples(graph)

      case non_violation_shapes(triples) do
        [] -> {:ok, :no_non_violation_shapes}
        shapes -> partition(graph, triples, MapSet.new(shapes))
      end
    end
  end

  defp non_violation_shapes(triples) do
    for {s, p, o} <- triples,
        to_string(p) == @sh <> "severity",
        to_string(o) in @non_violation,
        uniq: true,
        do: s
  end

  defp partition(graph, triples, shapes) do
    closed =
      for {s, p, o} <- triples, iri?(p, "closed"), true_literal?(o), into: MapSet.new(), do: s

    blocker =
      Enum.find_value(triples, fn {s, p, o} ->
        cond do
          MapSet.member?(shapes, o) and not iri?(p, "property") ->
            %{reason: :referenced_by_non_property_edge, predicate: to_string(p)}

          MapSet.member?(shapes, o) and MapSet.member?(closed, s) ->
            %{reason: :property_of_closed_shape, shape: to_string(s)}

          MapSet.member?(shapes, s) and to_string(p) in @nesting ->
            %{reason: :carries_nested_shapes, predicate: to_string(p)}

          true ->
            nil
        end
      end)

    case blocker do
      nil ->
        kept =
          Enum.reject(triples, fn {s, p, o} ->
            MapSet.member?(shapes, s) or (iri?(p, "property") and MapSet.member?(shapes, o))
          end)

        law = RDF.Turtle.write_string!(RDF.Graph.new(kept, prefixes: RDF.Graph.prefixes(graph)))
        {:ok, %{violations_only: law, removed: MapSet.size(shapes)}}

      detail ->
        {:error, Map.put(detail, :code, :shacl_severity_not_partitionable)}
    end
  end

  defp iri?(term, local), do: to_string(term) == @sh <> local

  defp true_literal?(%RDF.Literal{} = literal), do: RDF.Literal.value(literal) == true
  defp true_literal?(_), do: false

  @doc false
  def __sa2a_refusal_codes__, do: %{shacl_severity_not_partitionable: :refused_shacl}
end
