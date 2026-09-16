defmodule AshA2A.Semantic.Ontology do
  @moduledoc """
  Deterministic RDF-shaped projection of admitted SemanticIR.

  ## Two digests, and why they are not interchangeable

  This module exposes two different notions of "the identity of this
  projection". They answer different questions and only one of them
  satisfies RFC-SA2A-001 S12.

  ### `:fingerprint` (the struct field) -- sort-then-hash, NOT canonical

  `from_ir/1` populates `:fingerprint` with
  `SHA-256(:erlang.term_to_binary(sorted_triple_list))`. Its real, precise
  limitation:

    * It **is** stable under the order in which triples were generated,
      because the list is sorted by `{subject, predicate, object}` first.
    * It is **not** invariant under RDF graph isomorphism. A sort-then-hash
      over a concrete term list distinguishes graphs that RDF semantics
      considers identical (notably any relabelling of blank nodes) and is
      sensitive to the Erlang term encoding of the list itself. It is a
      digest of *this data structure*, not of *the graph it denotes*.
    * It is computed entirely in Elixir with `:crypto`, so it shares no
      implementation with the engine a remote peer runs, and two peers
      cannot meaningfully compare it.

  It is retained unchanged because it is load-bearing, already tested, and
  adequate for its actual job: cheap local change-detection on a projection
  this process just built. It must not be used as portable semantic
  identity.

  ### `canonical_digest/1` -- real canonicalization, S12-conformant

  `canonical_digest/1` serialises the triples to N-Triples and hands them to
  the real `praxis-graphlaw` engine via `AshA2A.GraphLaw.Wasm.graph_hash/2`,
  which canonicalizes (RDFC-1.0 family, via `oxrdf`'s `rdfc-10` feature)
  before hashing. This is the digest two peers can compare, and the one
  `AshA2A.Semantic.AdmissionHash` consumes. It requires the engine to be
  present and returns a typed `{:error, map}` when it is not.

  `canonical_digest/1` was **added** rather than swapped in behind
  `:fingerprint`: changing the existing field's meaning in place would have
  silently altered a tested, load-bearing value, and would have made a
  local, always-available digest depend on an external wasm artifact.
  """

  alias AshA2A.GraphLaw.Wasm
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

  # Sort-then-hash over the concrete triple list. Order-invariant (the list
  # is pre-sorted by the caller) but NOT isomorphism-invariant -- see the
  # moduledoc. Local change-detection only; never portable identity.
  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Canonical graph digest of this projection, computed by the real engine.

  Accepts an `%AshA2A.Semantic.Ontology{}` or a bare triple list. Serialises
  to N-Triples via `to_ntriples/1` and delegates to
  `AshA2A.GraphLaw.Wasm.graph_hash/2`, so the returned digest is invariant
  under triple order and under the prefix labels used to write the graph --
  properties `:fingerprint` does not have.

  Returns `{:ok, hex}` or a typed `{:error, map}` (including
  `%{code: :graphlaw_wasm_not_found}` when the engine artifact is absent).
  """
  @spec canonical_digest(t() | [map()], keyword()) :: {:ok, String.t()} | {:error, map()}
  def canonical_digest(ontology_or_triples, opts \\ [])

  def canonical_digest(%__MODULE__{triples: triples}, opts),
    do: canonical_digest(triples, opts)

  def canonical_digest(triples, opts) when is_list(triples),
    do: triples |> to_ntriples() |> Wasm.graph_hash(opts)

  @doc """
  Serialises this projection's triples to N-Triples.

  N-Triples (rather than Turtle) deliberately: it has no prefixes, no
  abbreviations and exactly one way to write each term, so the text handed
  to the engine carries no serialisation choices of its own. The engine
  canonicalizes regardless, but this keeps the Elixir side free of anything
  resembling a semantic decision.

  Object typing uses one documented rule: an object that is an absolute IRI
  (a scheme-prefixed string containing none of the characters N-Triples
  forbids in an IRI reference) is written as `<iri>`; every other object is
  written as a plain literal `"..."` with `\\\\`, `"`, `\\n`, `\\r` and `\\t`
  escaped. Subjects and predicates are always IRIs -- `Vocabulary.expand/1`
  and `Vocabulary.local/1` never return anything else.

  ## Statements are emitted as a set

  Rendered statements are deduplicated and byte-sorted before joining. An
  RDF graph is a *set* of triples, but the engine's `graph_hash` was
  measured to be duplicate-sensitive on the wire: feeding it the same
  statement twice yields a different digest than feeding it once (see
  `test/ash_a2a/semantic_ontology_canonical_digest_test.exs`, which pins
  that measured behaviour). Emitting the set here makes
  `canonical_digest/2` duplicate-invariant, which is what S12 requires of
  two peers that happened to serialise the same `O*` with different
  multiplicity.

  This is serialisation hygiene, not semantics: deduplicating identical
  rendered lines and sorting bytes is not graph canonicalization. All
  isomorphism-invariance -- blank-node labelling in particular -- remains
  entirely the engine's job, and the byte sort here is a plain
  `Enum.sort/1`, not an RDF canonical ordering.
  """
  @spec to_ntriples(t() | [map()]) :: String.t()
  def to_ntriples(%__MODULE__{triples: triples}), do: to_ntriples(triples)

  def to_ntriples(triples) when is_list(triples) do
    triples
    |> Enum.map(fn %{subject: s, predicate: p, object: o} ->
      "<#{escape_iri(s)}> <#{escape_iri(p)}> #{object_term(o)} .\n"
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join()
  end

  # RFC 3987 / N-Triples forbid these in an IRIREF; a string carrying any of
  # them is treated as a literal even if it looks scheme-prefixed.
  @forbidden_in_iri ["<", ">", "\"", "{", "}", "|", "^", "`", "\\", " ", "\t", "\n", "\r"]

  defp object_term(object) when is_binary(object) do
    if absolute_iri?(object), do: "<#{object}>", else: literal(object)
  end

  defp object_term(object), do: object |> to_string() |> object_term()

  defp absolute_iri?(value) do
    Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.\-]*:/, value) and
      not Enum.any?(@forbidden_in_iri, &String.contains?(value, &1))
  end

  defp escape_iri(value), do: to_string(value)

  defp literal(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
