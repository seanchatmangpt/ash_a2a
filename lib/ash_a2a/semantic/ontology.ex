defmodule AshA2A.Semantic.Ontology do
  @moduledoc "Deterministic RDF-shaped projection of admitted SemanticIR."

  alias AshA2A.Semantic.{IR, Vocabulary}

  @enforce_keys [:source_id, :triples, :fingerprint]
  defstruct [:source_id, :triples, :fingerprint, standing: :admitted, authority: :none]

  @type t :: %__MODULE__{}

  def from_ir(%IR{standing: :admitted, authority: :none} = ir) do
    ids =
      ir |> IR.items() |> Enum.map(fn {_field, item} -> Map.get(item, "id") end) |> MapSet.new()

    triples = base_triples(ir) ++ relation_triples(ir.relations, ids)
    triples = Enum.sort_by(triples, &{&1.subject, &1.predicate, to_string(&1.object)})

    {:ok,
     %__MODULE__{source_id: ir.source_id, triples: triples, fingerprint: fingerprint(triples)}}
  end

  def from_ir(_), do: {:error, %{code: :ontology_requires_admitted_semantics}}

  defp base_triples(ir) do
    Enum.flat_map(IR.items(ir), fn {field, item} ->
      subject = semantic_node(Map.fetch!(item, "id"))
      value = Map.get(item, "description") || Map.get(item, "label") || Map.fetch!(item, "kind")

      [
        triple(subject, Vocabulary.expand("rdf:type"), Vocabulary.local(field)),
        triple(subject, Vocabulary.expand("schema:description"), value),
        triple(subject, Vocabulary.expand("prov:wasDerivedFrom"), source(ir.source_id))
      ] ++ entity_type(field, item, subject)
    end)
  end

  defp entity_type(:entities, %{"type" => type}, subject),
    do: [triple(subject, Vocabulary.expand("rdf:type"), Vocabulary.expand(type))]

  defp entity_type(_, _, _), do: []

  defp relation_triples(relations, ids) do
    Enum.map(relations, fn relation ->
      object = Map.fetch!(relation, "object")
      object = if MapSet.member?(ids, object), do: semantic_node(object), else: object

      triple(
        semantic_node(Map.fetch!(relation, "subject")),
        Vocabulary.expand(Map.fetch!(relation, "predicate")),
        object
      )
    end)
  end

  defp triple(subject, predicate, object),
    do: %{subject: subject, predicate: predicate, object: object}

  defp semantic_node(id), do: "urn:ash-a2a:semantic:node:#{id}"
  defp source(id), do: "urn:ash-a2a:source:#{id}"

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
