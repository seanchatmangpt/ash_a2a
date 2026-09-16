defmodule AshA2A.Semantic.CanonicalDigest do
  @moduledoc """
  The real `Ontology -> serialize -> verify -> native canonical hash` path.

  RFC-SA2A-001 S12 requires graph identity to be a property of the *RDF graph*,
  not of the BEAM term that happens to carry it. `AshA2A.Semantic.Ontology`'s
  own `fingerprint/1` is a sort-then-`:erlang.term_to_binary`-then-SHA-256 --
  a stable digest of an Elixir term, which is a different thing. This module
  is the supplement that closes that gap without touching `Ontology`: it hands
  the graph to the real native engine and reports what the engine says.

  ## The pipeline, and why each hop exists

      %Ontology{}
        |> AshA2A.Semantic.Serialize.to_ntriples/1     # bytes the engine can parse
        |> AshA2A.Semantic.Serialize.verify/3          # independent parse-back gate
        |> AshA2A.Semantic.GraphLawBridge.graph_hash/2 # real praxis-graphlaw wasm

  The middle hop is not defensive decoration. A real probe of the real wasm
  established that `graph_hash/1` silently drops unparseable input with no
  error channel and no triple count -- `graph_hash(good <> "GARBAGE !!!")`
  returned bit-for-bit the same digest as `graph_hash(good)`, and
  `graph_hash("GARBAGE !!!")` returned `af1349b9f5f9a1a6...`, which is
  `BLAKE3("")`. Without an independent parse-back, a serializer defect
  produces a confident, valid-looking digest *of a different graph*. The
  verify hop turns that silent corruption into a typed refusal.

  ## What this digest is, and is not (measured)

  Measured properties of the engine's `graph_hash/1`:

    * **Order independent.** The same triples in a different textual order,
      under a different prefix label, hash identically.
    * **Syntax independent.** The same graph as prefixed Turtle and as
      N-Triples hash identically.
    * **RDF 1.1 literal semantics.** `"hi"` and `"hi"^^xsd:string` hash
      identically; `"hi"@en` and `"42"^^xsd:integer` do not.
    * **NOT duplicate-insensitive.** Repeating a triple changes the digest, so
      it is a multiset digest rather than a digest of the RDF *set*. This
      module therefore reports `triple_count` and `distinct_triple_count`
      separately and refuses to describe the result as an RDF-set canonical
      form.
    * **NOT blank-node canonical.** Relabelling a blank node changes the
      digest, so this is not RDFC-1.0 isomorphism canonicalization despite
      the crate enabling oxrdf's `rdfc-10` feature.

  Those last two are named explicitly because the SA2A conformance claim is
  about two runtimes agreeing on the same engine, not about universal RDF
  graph-isomorphism equivalence. Overstating what `graph_hash/1` does would
  overstate the qualification. RFC S12 canonical graph identity (RDFC-1.0,
  blank-node-relabel invariant) is `AshA2A.Semantic.CanonicalGraph`; this
  module's digest is the engine digest and must not be substituted for it.
  """

  alias AshA2A.Semantic.{GraphLawBridge, Ontology, Serialize}

  @type t :: %{
          algorithm: :graphlaw_graph_hash,
          format: :ntriples | :turtle,
          digest: String.t(),
          engine_version: String.t(),
          host: :in_beam | :node_shim,
          triple_count: non_neg_integer(),
          distinct_triple_count: non_neg_integer(),
          document_bytes: non_neg_integer()
        }

  @doc """
  Serializes, verifies, and hashes an `%Ontology{}` (or a bare triple list)
  through the real native engine.

  Options:

    * `:format` -- `:ntriples` (default) or `:turtle`.
    * `:verify` -- `false` skips the independent parse-back gate. Defaults to
      `true`; turning it off means accepting the silent-truncation hazard
      documented above, so the resulting map is tagged `verified: false`.

  Returns `{:ok, map}` or `{:error, map}` carrying a `:code`.
  """
  @spec canonical_digest(Ontology.t() | [map()], keyword()) :: {:ok, map()} | {:error, map()}
  def canonical_digest(subject, opts \\ [])

  def canonical_digest(%Ontology{triples: triples}, opts), do: canonical_digest(triples, opts)

  def canonical_digest(triples, opts) when is_list(triples) do
    format = Keyword.get(opts, :format, :ntriples)
    verify? = Keyword.get(opts, :verify, true)

    with {:ok, document} <- serialize(triples, format, opts),
         {:ok, distinct} <- gate(verify?, triples, document, format, opts),
         {:ok, digest} <- GraphLawBridge.graph_hash(document, opts),
         :ok <- reject_error_payload(digest),
         {:ok, version} <- GraphLawBridge.version(opts) do
      {:ok,
       %{
         algorithm: :graphlaw_graph_hash,
         format: format,
         digest: digest,
         engine_version: version,
         host: GraphLawBridge.host(opts),
         verified: verify?,
         triple_count: length(triples),
         distinct_triple_count: distinct,
         document_bytes: byte_size(document)
       }}
    end
  end

  def canonical_digest(other, _opts),
    do: {:error, %{code: :canonical_digest_expected_triples, detail: other}}

  @doc """
  Just the digest hex string, for call sites that only need the identity.
  """
  @spec digest(Ontology.t() | [map()], keyword()) :: {:ok, String.t()} | {:error, map()}
  def digest(subject, opts \\ []) do
    with {:ok, %{digest: digest}} <- canonical_digest(subject, opts), do: {:ok, digest}
  end

  @doc """
  The serialized RDF document that would be hashed, after the parse-back gate.

  Exposed so a receipt can carry the exact bytes the digest was taken over --
  the digest alone is not replayable, the bytes are.
  """
  @spec document(Ontology.t() | [map()], keyword()) :: {:ok, binary()} | {:error, map()}
  def document(subject, opts \\ [])
  def document(%Ontology{triples: triples}, opts), do: document(triples, opts)

  def document(triples, opts) when is_list(triples) do
    format = Keyword.get(opts, :format, :ntriples)

    with {:ok, doc} <- serialize(triples, format, opts),
         {:ok, _distinct} <- gate(Keyword.get(opts, :verify, true), triples, doc, format, opts) do
      {:ok, doc}
    end
  end

  # The parse-back gate.
  #
  # For `:ntriples` this is a straight `Serialize.verify/3` against RDF.ex's
  # N-Triples decoder, which a real differential probe confirmed handles
  # ECHAR and UCHAR correctly in plain, language-tagged and typed literals
  # alike.
  #
  # For `:turtle` it cannot be, because RDF.ex 3.0.1's *Turtle* decoder has a
  # real, measured defect: it does not unescape ECHAR/UCHAR inside a
  # `^^`-typed literal (`"x\\"y"^^xsd:integer` decodes with the lexical form
  # `x\\"y`), while handling plain and language-tagged literals correctly and
  # while its own N-Triples decoder handles all three correctly. See
  # `AshA2A.Semantic.SerializeTest`'s "RDF.ex 3.0.1 Turtle decoder defect"
  # block, which pins the exact evidence.
  #
  # So the Turtle path is gated by two real checks that are *not* subject to
  # that defect instead of one that is: the N-Triples rendering of the same
  # triples is parse-back verified, and the native engine is then required to
  # produce the *same* canonical digest for the Turtle document as for the
  # verified N-Triples document. A serializer bug in the Turtle writer would
  # have to survive both.
  defp gate(false, triples, _document, _format, _opts),
    do: {:ok, triples |> Enum.map(&canonical_key/1) |> Enum.uniq() |> length()}

  defp gate(true, triples, _document, :ntriples, _opts) do
    with {:ok, nt} <- Serialize.to_ntriples(triples),
         do: Serialize.verify(triples, nt, format: :ntriples)
  end

  defp gate(true, triples, turtle_document, :turtle, opts) do
    with {:ok, nt} <- Serialize.to_ntriples(triples),
         {:ok, distinct} <- Serialize.verify(triples, nt, format: :ntriples),
         {:ok, [turtle_hash, ntriples_hash]} <-
           GraphLawBridge.call_many(
             [{"graph_hash", [turtle_document]}, {"graph_hash", [nt]}],
             opts
           ) do
      if turtle_hash == ntriples_hash do
        {:ok, distinct}
      else
        {:error,
         %{
           code: :canonical_digest_turtle_ntriples_disagree,
           turtle_hash: turtle_hash,
           ntriples_hash: ntriples_hash
         }}
      end
    end
  end

  defp serialize(triples, :ntriples, _opts), do: Serialize.to_ntriples(triples)
  defp serialize(triples, :turtle, opts), do: Serialize.to_turtle(triples, opts)

  defp serialize(_triples, format, _opts),
    do: {:error, %{code: :canonical_digest_unknown_format, detail: format}}

  defp canonical_key(%{subject: s, predicate: p, object: o}), do: {s, p, o}
  defp canonical_key(other), do: other

  # graph_hash/1 returns {"error": "..."} JSON rather than raising; a 64-hex
  # digest is the only shape we accept as an identity.
  defp reject_error_payload(digest) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, digest) do
      :ok
    else
      case Serialize.from_json(digest) do
        {:error, reason} -> {:error, reason}
        {:ok, decoded} -> {:error, %{code: :graphlaw_unexpected_digest, detail: decoded}}
      end
    end
  end
end
