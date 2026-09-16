defmodule AshA2A.SA2A.ResultProjection do
  @moduledoc """
  Deterministic projections of GraphLaw's JSON results into the two canonical
  forms the conformance court hashes.

  ## Why a projection exists at all

  The court's fifth call is `graph_hash(result-of-hooks)` -- the canonical
  hash of the *result*, not of its printed form. `run_hooks/2` returns JSON,
  and hashing that JSON text would compare serialisations rather than
  semantics. So the parsed result is projected into a small RDF graph and
  handed back to GraphLaw's own `graph_hash` (prefix- and
  triple-order-invariant; not RDFC-1.0, because it is not blank-node-relabel
  invariant -- RFC S12 identity is `AshA2A.Semantic.CanonicalGraph`). Two
  runtimes that produced the same hook result then agree on
  `output_graph_hash` no matter how either one printed it; two runtimes that
  produced different results cannot agree, whatever the printing.

  This module builds *input* for the engine hash. It does not canonicalize
  RDF, and it must never be mistaken for doing so -- the engine digest is
  computed inside `praxis-graphlaw`, reached through
  `AshA2A.GraphLaw.Runtime.call/3`.

  ## The one real nondeterminism source, and how it is neutralised

  `PlaygroundResult.hash_algorithms` is a Rust `HashMap`, so its
  `serde_json` serialisation has no guaranteed key order and the raw
  `validate_all/5` JSON string is therefore *not* canonical. Hashing that raw
  string would produce spurious cross-runtime divergence. `validation_summary/1`
  reads the parsed fields in fixed order and sorts that map's entries, which
  is why the court hashes the summary and never the raw payload.
  """

  @ns "urn:sa2a:conformance:"
  @xsd "http://www.w3.org/2001/XMLSchema#"

  @doc """
  Projects a parsed `run_hooks/2` result into a small Turtle graph whose
  canonical hash is the vector's `output_graph_hash`.

  Verdicts and receipts are carried as canonical-JSON string literals: their
  internal shape is GraphLaw's to define, and re-modelling it as RDF here
  would be this module inventing semantics it has no authority over. What
  matters for conformance is that identical results project to an identical
  graph and different results do not.
  """
  @spec hook_result_turtle(String.t(), map()) :: String.t()
  def hook_result_turtle(vector_id, %{} = hooks) when is_binary(vector_id) do
    subject = "<#{@ns}hookrun:#{vector_id}>"
    verdicts = List.wrap(Map.get(hooks, "verdicts", []))
    receipts = List.wrap(Map.get(hooks, "receipts", []))
    schedule = List.wrap(Map.get(hooks, "schedule", []))

    header = """
    @prefix sa2a: <#{@ns}> .
    @prefix xsd: <#{@xsd}> .
    """

    core = [
      triple(subject, "sa2a:status", literal(to_string(Map.get(hooks, "status", "ABSENT")))),
      triple(subject, "sa2a:verdictCount", integer(length(verdicts))),
      triple(subject, "sa2a:receiptCount", integer(length(receipts))),
      triple(subject, "sa2a:scheduleLength", integer(length(schedule)))
    ]

    scheduled =
      schedule
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        node = "<#{@ns}hookrun:#{vector_id}:schedule:#{index}>"

        [
          triple(subject, "sa2a:hasScheduleEntry", node),
          triple(node, "sa2a:index", integer(index)),
          triple(node, "sa2a:entry", literal(to_string(entry)))
        ]
      end)
      |> List.flatten()

    itemised =
      [{"hasVerdict", "verdict", verdicts}, {"hasReceipt", "receipt", receipts}]
      |> Enum.flat_map(fn {predicate, kind, items} ->
        items
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} ->
          node = "<#{@ns}hookrun:#{vector_id}:#{kind}:#{index}>"

          [
            triple(subject, "sa2a:#{predicate}", node),
            triple(node, "sa2a:index", integer(index)),
            triple(node, "sa2a:canonicalJson", literal(canonical_json(item)))
          ]
        end)
      end)

    header <> "\n" <> Enum.join(core ++ scheduled ++ itemised, "\n") <> "\n"
  end

  @doc """
  Canonical, order-stable summary of a parsed `validate_all/5` result.

  Every field is read in fixed order and `hash_algorithms` is sorted, so this
  string is a faithful, reproducible digest input for a payload whose raw
  JSON is not.
  """
  @spec validation_summary(map()) :: String.t()
  def validation_summary(%{} = result) do
    dialects =
      result
      |> Map.get("dialects", [])
      |> List.wrap()
      |> Enum.map_join("", fn dialect ->
        "dialect:#{Map.get(dialect, "dialect")}=" <>
          "#{Map.get(dialect, "status")}|" <>
          "#{Map.get(dialect, "triples_out")}|" <>
          "#{Map.get(dialect, "detail")}\n"
      end)

    replay = Map.get(result, "replay", %{})
    hooks = Map.get(result, "hooks", %{})

    algorithms =
      result
      |> Map.get("hash_algorithms", %{})
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)

    """
    graph_hash=#{Map.get(result, "graph_hash")}
    profile_hash=#{Map.get(result, "profile_hash")}
    #{dialects}replay=#{Map.get(replay, "status")}|#{Map.get(replay, "first_hash")}|#{Map.get(replay, "second_hash")}
    hooks=#{Map.get(hooks, "status")}|#{length(List.wrap(Map.get(hooks, "verdicts", [])))}|#{length(List.wrap(Map.get(hooks, "receipts", [])))}|#{Enum.join(List.wrap(Map.get(hooks, "schedule", [])), ",")}
    hash_algorithms=#{algorithms}
    """
  end

  @doc """
  Deterministic JSON encoding with lexicographically sorted object keys.

  `JSON.encode!/1` preserves no key order across maps, so it cannot be used
  for digest input. This is a key-ordering discipline for building a hash
  input, not an RDF canonicalization.

      iex> AshA2A.SA2A.ResultProjection.canonical_json(%{"b" => 1, "a" => [true, nil]})
      ~s({"a":[true,null],"b":1})
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value) when is_map(value) do
    body =
      value
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} ->
        JSON.encode!(to_string(k)) <> ":" <> canonical_json(v)
      end)

    "{" <> body <> "}"
  end

  def canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  def canonical_json(value), do: JSON.encode!(value)

  @doc """
  Escapes a string for use as a Turtle short-form literal.

      iex> AshA2A.SA2A.ResultProjection.escape_literal(~s(a"b\\\\c))
      ~s(a\\\\"b\\\\\\\\c)
  """
  @spec escape_literal(String.t()) :: String.t()
  def escape_literal(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp triple(subject, predicate, object), do: "#{subject} #{predicate} #{object} ."
  defp literal(value), do: "\"" <> escape_literal(value) <> "\""
  defp integer(value), do: "\"#{value}\"^^xsd:integer"
end
