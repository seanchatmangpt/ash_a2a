defmodule AshA2A.Semantic.Serialize do
  @moduledoc """
  The thin Elixir <-> RDF serialization boundary, and *only* the thin boundary.

  This module turns `AshA2A.Semantic.Ontology`'s in-BEAM triple structs into
  a byte string the native RDF engine (praxis-graphlaw) can parse, and reads
  that engine's JSON result payloads back. It performs **no** validation, no
  reasoning, no entailment, no canonicalization, and no graph hashing --
  every one of those stays in the native engine (RFC-SA2A-001 S12/S79). The
  only thing Elixir is allowed to own here is bytes in and bytes out.

  ## Why serializer correctness is load-bearing (measured, not assumed)

  A real probe of the real prebuilt
  `praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm` (3,249,361 bytes,
  `graphlaw_version() == "praxis-graphlaw v26.7.5"`) established that
  `graph_hash/1` has **no parse-error channel and reports no parsed-triple
  count**:

      graph_hash("<http://e/a> <http://e/p> <http://e/b> .")
        -> c4e31e0b868638234e85a6a06683937d2928f4c83f3572ed9a972da4605525f0
      graph_hash("<http://e/a> <http://e/p> <http://e/b> .\\nGARBAGE !!!")
        -> c4e31e0b868638234e85a6a06683937d2928f4c83f3572ed9a972da4605525f0   # identical
      graph_hash("GARBAGE !!!")  -> af1349b9f5f9a1a6...  # == BLAKE3("") == graph_hash("")

  A malformed serialization therefore does not raise, does not return
  `{"error": ...}`, and does not produce a distinguishable digest -- it
  silently degrades to a *smaller or empty* graph carrying a perfectly
  valid-looking canonical digest. Under RFC S12 that digest then flows into
  receipts and standing. So a serializer bug here is not a cosmetic defect;
  it is a silent-corruption hazard at the exact hop the SA2A conformance
  claim rests on.

  That measurement is why `verify/2` exists and why the digest path in
  `AshA2A.Semantic.CanonicalDigest` gates on it: the only way to detect
  silent truncation is to parse our own output back with an *independent*
  real parser and require term-for-term agreement.

  ## Term representation

  `AshA2A.Semantic.Ontology` triples are `%{subject:, predicate:, object:}`
  where every field is a bare binary and the object is *sometimes* an IRI
  (`"urn:ash-a2a:semantic:node:e2"`) and *sometimes* a literal (`"Alice"`,
  `"nowhere"`) with no type tag distinguishing them. This module accepts
  both an explicit, unambiguous term form and that bare-binary form:

    * `{:iri, binary}`                     -- an absolute IRI
    * `{:bnode, binary}`                   -- blank node label (no `_:` prefix)
    * `{:literal, binary}`                 -- plain literal (`xsd:string`)
    * `{:literal, binary, datatype: iri}`  -- typed literal
    * `{:literal, binary, language: tag}`  -- language-tagged literal
    * `binary`                             -- **inferred**, see below

  ### The inference rule, and its exact limit

  In subject and predicate position the RDF grammar admits no literal, so a
  bare binary is always an IRI (subject may also be `{:bnode, _}`). In object
  position a bare binary is an IRI iff it matches an absolute-IRI shape
  (`scheme:` followed by no whitespace and no IRI-forbidden character), and a
  plain literal otherwise.

  This is a heuristic and it has one real false positive: a *literal whose
  text happens to look like an IRI* (a `schema:description` of
  `"mailto:ops@example.com"`) is serialized as an IRI. That is a property of
  `Ontology`'s untyped object field, not of this serializer, and the explicit
  `{:literal, v}` form is the escape hatch. It is stated here rather than
  left to be discovered.

  ## Escaping and IRI refusal

  Implemented against the RDF 1.1 N-Triples grammar directly:

    * `IRIREF` -- an IRI containing a character the grammar forbids inside
      `<...>` (`#x00-#x20`, `<`, `>`, `"`, `{`, `}`, `|`, `^`, `` ` ``, `\\`)
      is **refused** with `:serialize_invalid_iri`, not silently escaped.
      `\\u`-escaping such a character would produce a document that parses
      but denotes an IRI that is illegal under RFC 3987 -- exactly the class
      of quiet misrepresentation this boundary exists to prevent. Escaping is
      still applied (`escape_iri/1`) as a second line of defence on the
      already-validated IRIs that reach the writer, including `@prefix`
      namespaces and datatype IRIs. Non-ASCII IRIs (`http://e/café`,
      `http://e/日本`) are legal IRIs and pass through raw.
    * `STRING_LITERAL_QUOTE` -- `\\\\`, `\\"`, `\\n`, `\\r`, `\\t`, `\\b`,
      `\\f`, and `\\uXXXX` for every remaining C0/C1 control character.
      Non-ASCII printable text (accents, CJK, emoji, astral-plane
      codepoints) is emitted raw, which RDF 1.1 requires -- N-Triples is
      UTF-8.
    * `BLANK_NODE_LABEL` -- sanitized to `[A-Za-z0-9_]+`, never empty.
    * `LANGTAG` -- validated `[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*`.

  ## Turtle

  `to_turtle/2` emits a deterministic `@prefix` block (only prefixes actually
  used, sorted) plus one fully-terminated triple per line. It compacts an IRI
  to a `PNAME_LN` only when the local part matches a conservative strict
  subset of the `PN_LOCAL` grammar (`[A-Za-z_][A-Za-z0-9_-]*`); anything else
  is emitted as a full `<IRI>`. Conservative compaction can only ever make
  the output more verbose, never ambiguous.
  """

  alias AshA2A.Semantic.{Ontology, Vocabulary}

  @xsd "http://www.w3.org/2001/XMLSchema#"
  @xsd_string @xsd <> "string"
  @rdf_lang_string "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"

  # Characters the N-Triples IRIREF production forbids between < and >.
  @iri_forbidden [?<, ?>, ?", ?{, ?}, ?|, ?^, ?`, ?\\]

  @scheme_re ~r/^[A-Za-z][A-Za-z0-9+.\-]*:/
  @langtag_re ~r/^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$/
  @safe_pn_local_re ~r/^[A-Za-z_][A-Za-z0-9_\-]*$/

  @type iri :: binary()
  @type rdf_term ::
          {:iri, iri()}
          | {:bnode, binary()}
          | {:literal, binary()}
          | {:literal, binary(), keyword()}
          | binary()

  @type triple :: %{
          required(:subject) => any(),
          required(:predicate) => any(),
          required(:object) => any()
        }

  @doc """
  Serializes an `%Ontology{}` (or a bare list of triple maps) to RDF 1.1
  N-Triples.

  Returns `{:ok, binary}` or `{:error, map}` with a `:code` key. Every line is
  `subject predicate object .` terminated by `\\n`. An empty triple list
  serializes to `""`, which is the valid empty N-Triples document.

      iex> AshA2A.Semantic.Serialize.to_ntriples([
      ...>   %{subject: "http://e/a", predicate: "http://e/p", object: {:literal, "hi"}}
      ...> ])
      {:ok, ~s|<http://e/a> <http://e/p> "hi" .\\n|}
  """
  @spec to_ntriples(Ontology.t() | [triple()]) :: {:ok, binary()} | {:error, map()}
  def to_ntriples(%Ontology{triples: triples}), do: to_ntriples(triples)

  def to_ntriples(triples) when is_list(triples) do
    triples
    |> Enum.reduce_while({:ok, []}, fn triple, {:ok, acc} ->
      case encode_triple(triple) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join()}
      {:error, _} = error -> error
    end
  end

  def to_ntriples(other), do: {:error, %{code: :serialize_expected_triples, detail: other}}

  @doc """
  Serializes an `%Ontology{}` (or a bare list of triple maps) to RDF 1.1
  Turtle, with a deterministic `@prefix` header.

  Options:

    * `:prefixes` -- prefix map to compact against. Defaults to
      `AshA2A.Semantic.Vocabulary.prefixes/0` plus `xsd`.
    * `:compact` -- `false` disables PName compaction entirely (every term is
      emitted as a full `<IRI>`). Defaults to `true`.
  """
  @spec to_turtle(Ontology.t() | [triple()], keyword()) :: {:ok, binary()} | {:error, map()}
  def to_turtle(subject, opts \\ [])

  def to_turtle(%Ontology{triples: triples}, opts), do: to_turtle(triples, opts)

  def to_turtle(triples, opts) when is_list(triples) do
    prefixes = Keyword.get(opts, :prefixes, default_prefixes())
    compact? = Keyword.get(opts, :compact, true)

    triples
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn triple, {:ok, acc, used} ->
      case turtle_triple(triple, prefixes, compact?) do
        {:ok, line, line_used} -> {:cont, {:ok, [line | acc], MapSet.union(used, line_used)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines, used} ->
        header =
          used
          |> Enum.sort()
          |> Enum.map_join(fn prefix ->
            "@prefix #{prefix}: <#{escape_iri(Map.fetch!(prefixes, prefix))}> .\n"
          end)

        body = lines |> Enum.reverse() |> Enum.join()
        {:ok, if(header == "", do: body, else: header <> "\n" <> body)}

      {:error, _} = error ->
        error
    end
  end

  def to_turtle(other, _opts), do: {:error, %{code: :serialize_expected_triples, detail: other}}

  @doc """
  The prefix map used by `to_turtle/2` by default: every prefix in
  `AshA2A.Semantic.Vocabulary.prefixes/0` plus `xsd`, which Turtle needs for
  typed literals and which the runtime vocabulary registry does not carry.
  """
  @spec default_prefixes() :: %{binary() => binary()}
  def default_prefixes, do: Map.put(Vocabulary.prefixes(), "xsd", @xsd)

  @doc """
  Coerces a bare binary / explicit tuple into a canonical term tuple for the
  given grammar position (`:subject`, `:predicate`, `:object`).

  Returns `{:ok, {:iri, _} | {:bnode, _} | {:literal, _, opts}}` or
  `{:error, map}`.
  """
  @spec term(rdf_term(), :subject | :predicate | :object) ::
          {:ok, {:iri, binary()} | {:bnode, binary()} | {:literal, binary(), keyword()}}
          | {:error, map()}
  def term(value, position)

  def term({:iri, iri}, position) when is_binary(iri) do
    case classify_iri(iri) do
      :ok ->
        {:ok, {:iri, iri}}

      {:invalid, reason} ->
        {:error, %{code: :serialize_invalid_iri, reason: reason, position: position, detail: iri}}
    end
  end

  def term({:bnode, label}, position) when is_binary(label) do
    if position == :predicate do
      {:error, %{code: :serialize_bnode_in_predicate, detail: label}}
    else
      {:ok, {:bnode, sanitize_bnode(label)}}
    end
  end

  def term({:literal, value}, position) when is_binary(value),
    do: term({:literal, value, []}, position)

  def term({:literal, value, opts}, position) when is_binary(value) and is_list(opts) do
    cond do
      position != :object ->
        {:error,
         %{code: :serialize_literal_out_of_object_position, position: position, detail: value}}

      language = Keyword.get(opts, :language) ->
        if is_binary(language) and Regex.match?(@langtag_re, language),
          do: {:ok, {:literal, value, language: language}},
          else: {:error, %{code: :serialize_invalid_language_tag, detail: language}}

      datatype = Keyword.get(opts, :datatype) ->
        case datatype do
          dt when is_binary(dt) ->
            case classify_iri(dt) do
              :ok ->
                {:ok, {:literal, value, datatype: dt}}

              {:invalid, reason} ->
                {:error,
                 %{code: :serialize_invalid_iri, reason: reason, position: :datatype, detail: dt}}
            end

          other ->
            {:error, %{code: :serialize_invalid_datatype, detail: other}}
        end

      true ->
        {:ok, {:literal, value, []}}
    end
  end

  def term(value, :object) when is_binary(value) do
    if absolute_iri?(value),
      do: {:ok, {:iri, value}},
      else: {:ok, {:literal, value, []}}
  end

  def term(value, position) when is_binary(value) and position in [:subject, :predicate] do
    case classify_iri(value) do
      :ok ->
        {:ok, {:iri, value}}

      {:invalid, reason} ->
        {:error,
         %{code: :serialize_invalid_iri, reason: reason, position: position, detail: value}}
    end
  end

  def term(value, position),
    do: {:error, %{code: :serialize_unsupported_term, position: position, detail: value}}

  @doc """
  Encodes one canonical term tuple to its N-Triples lexical form.
  """
  @spec encode_term({:iri, binary()} | {:bnode, binary()} | {:literal, binary(), keyword()}) ::
          binary()
  def encode_term({:iri, iri}), do: "<" <> escape_iri(iri) <> ">"
  def encode_term({:bnode, label}), do: "_:" <> label

  def encode_term({:literal, value, opts}) do
    quoted = "\"" <> escape_literal(value) <> "\""

    cond do
      language = Keyword.get(opts, :language) -> quoted <> "@" <> language
      datatype = Keyword.get(opts, :datatype) -> quoted <> "^^<" <> escape_iri(datatype) <> ">"
      true -> quoted
    end
  end

  @doc """
  Independent parse-back gate.

  Re-parses `serialized` with the real `RDF.ex` parser (`RDF.NTriples.Decoder`
  or `RDF.Turtle.Decoder`, a genuinely separate implementation from this
  module's own encoder) and requires that the resulting `RDF.Graph`'s triple
  set is exactly the triple set this module intended to emit.

  This is the only defence against the measured silent-truncation behaviour
  documented in this module's `@moduledoc`: praxis-graphlaw's `graph_hash/1`
  drops unparseable input without any error signal, so an encoder bug would
  otherwise produce a confident digest of a *different, smaller* graph.

  Returns `{:ok, count}` where `count` is the number of distinct parsed
  triples, or `{:error, map}`.

  ## Known oracle defect: `format: :turtle` and typed literals

  A real differential probe of the real `rdf` 3.0.1 package established that
  its **Turtle** decoder does not unescape `ECHAR`/`UCHAR` inside a
  `^^`-typed literal, while handling plain and language-tagged literals
  correctly, and while its own **N-Triples** decoder handles all three
  correctly:

      Turtle    "x\\"y"                    -> lexical  x"y      (correct)
      Turtle    "x\\"y"@en                 -> lexical  x"y      (correct)
      Turtle    "x\\"y"^^xsd:integer       -> lexical  x\\"y     (WRONG)
      N-Triples "x\\"y"^^<...#integer>     -> lexical  x"y      (correct)

  That is a defect in the oracle, not in this module's writer -- the two
  serializations carry byte-identical literal syntax and only the Turtle
  decoder disagrees. So `verify/3` with `format: :turtle` will report a
  `:serialize_round_trip_mismatch` for a typed literal containing an
  escapable character even though the emitted Turtle is correct.

  `AshA2A.Semantic.CanonicalDigest` therefore does **not** gate the Turtle
  path on this function. It verifies the N-Triples rendering of the same
  triples (where the oracle is sound) and then requires the native engine to
  return the same canonical digest for both documents.

  Note that `count` is the size of the RDF *set*, so it is less than
  `length(triples)` when the input contains duplicate triples. That is
  correct RDF semantics and is asserted on rather than hidden -- see
  `AshA2A.Semantic.CanonicalDigest`, which reports both numbers.
  """
  @spec verify([triple()] | Ontology.t(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, map()}
  def verify(subject, serialized, opts \\ [])

  def verify(%Ontology{triples: triples}, serialized, opts), do: verify(triples, serialized, opts)

  def verify(triples, serialized, opts) when is_list(triples) and is_binary(serialized) do
    format = Keyword.get(opts, :format, :ntriples)

    with {:ok, expected} <- canonical_term_set(triples),
         {:ok, graph} <- decode(serialized, format) do
      actual =
        graph
        |> RDF.Graph.triples()
        |> MapSet.new(&rdf_ex_triple_to_canonical/1)

      cond do
        MapSet.equal?(expected, actual) ->
          {:ok, MapSet.size(actual)}

        true ->
          {:error,
           %{
             code: :serialize_round_trip_mismatch,
             expected_count: MapSet.size(expected),
             actual_count: MapSet.size(actual),
             missing: expected |> MapSet.difference(actual) |> Enum.take(5),
             unexpected: actual |> MapSet.difference(expected) |> Enum.take(5)
           }}
      end
    end
  end

  @doc """
  Decodes one of praxis-graphlaw's JSON result payloads (`validate_all/5`,
  `run_hooks/2`, and the `{"error": ...}` form `graph_hash/1` can return).

  Every graphlaw export returns `{"error": "..."}` as a *successful* JSON
  string rather than throwing, so callers must check for the key -- this
  function does it once, centrally, and turns it into a typed refusal.
  """
  @spec from_json(binary()) :: {:ok, map()} | {:error, map()}
  def from_json(payload) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, %{"error" => detail}} -> {:error, %{code: :graphlaw_error, detail: detail}}
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, %{code: :graphlaw_unexpected_payload, detail: other}}
      {:error, reason} -> {:error, %{code: :graphlaw_non_json, reason: reason, raw: payload}}
    end
  end

  def from_json(other), do: {:error, %{code: :graphlaw_non_binary_payload, detail: other}}

  # -- encoding ------------------------------------------------------------

  defp encode_triple(%{subject: s, predicate: p, object: o}) do
    with {:ok, st} <- term(s, :subject),
         {:ok, pt} <- term(p, :predicate),
         {:ok, ot} <- term(o, :object) do
      {:ok, encode_term(st) <> " " <> encode_term(pt) <> " " <> encode_term(ot) <> " .\n"}
    end
  end

  defp encode_triple(other), do: {:error, %{code: :serialize_malformed_triple, detail: other}}

  defp turtle_triple(%{subject: s, predicate: p, object: o}, prefixes, compact?) do
    with {:ok, st} <- term(s, :subject),
         {:ok, pt} <- term(p, :predicate),
         {:ok, ot} <- term(o, :object) do
      {s_text, u1} = turtle_term(st, prefixes, compact?)
      {p_text, u2} = turtle_term(pt, prefixes, compact?)
      {o_text, u3} = turtle_term(ot, prefixes, compact?)

      {:ok, s_text <> " " <> p_text <> " " <> o_text <> " .\n",
       MapSet.union(u1, MapSet.union(u2, u3))}
    end
  end

  defp turtle_triple(other, _prefixes, _compact?),
    do: {:error, %{code: :serialize_malformed_triple, detail: other}}

  defp turtle_term({:iri, iri}, prefixes, compact?), do: turtle_iri(iri, prefixes, compact?)
  defp turtle_term({:bnode, label}, _prefixes, _compact?), do: {"_:" <> label, MapSet.new()}

  defp turtle_term({:literal, value, opts}, prefixes, compact?) do
    quoted = "\"" <> escape_literal(value) <> "\""

    cond do
      language = Keyword.get(opts, :language) ->
        {quoted <> "@" <> language, MapSet.new()}

      datatype = Keyword.get(opts, :datatype) ->
        {dt_text, used} = turtle_iri(datatype, prefixes, compact?)
        {quoted <> "^^" <> dt_text, used}

      true ->
        {quoted, MapSet.new()}
    end
  end

  defp turtle_iri(iri, prefixes, true) do
    case compact(iri, prefixes) do
      {:ok, prefix, local} -> {prefix <> ":" <> local, MapSet.new([prefix])}
      :error -> {"<" <> escape_iri(iri) <> ">", MapSet.new()}
    end
  end

  defp turtle_iri(iri, _prefixes, false), do: {"<" <> escape_iri(iri) <> ">", MapSet.new()}

  defp compact(iri, prefixes) do
    prefixes
    |> Enum.sort_by(fn {_prefix, namespace} -> -byte_size(namespace) end)
    |> Enum.find_value(:error, fn {prefix, namespace} ->
      case iri do
        <<^namespace::binary, local::binary>> ->
          if local != "" and Regex.match?(@safe_pn_local_re, local),
            do: {:ok, prefix, local},
            else: nil

        _ ->
          nil
      end
    end)
  end

  # -- escaping ------------------------------------------------------------

  @doc false
  def escape_iri(iri) when is_binary(iri) do
    iri
    |> String.to_charlist()
    |> Enum.map_join(fn
      c when c <= 0x20 -> uchar(c)
      c when c in @iri_forbidden -> uchar(c)
      c -> <<c::utf8>>
    end)
  end

  @doc false
  def escape_literal(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> Enum.map_join(fn
      ?\\ -> "\\\\"
      ?" -> "\\\""
      ?\n -> "\\n"
      ?\r -> "\\r"
      ?\t -> "\\t"
      ?\b -> "\\b"
      ?\f -> "\\f"
      c when c <= 0x1F or c == 0x7F -> uchar(c)
      c when c >= 0x80 and c <= 0x9F -> uchar(c)
      c -> <<c::utf8>>
    end)
  end

  defp uchar(c) when c <= 0xFFFF,
    do: "\\u" <> (c |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.upcase())

  defp uchar(c),
    do: "\\U" <> (c |> Integer.to_string(16) |> String.pad_leading(8, "0") |> String.upcase())

  defp sanitize_bnode(label) do
    cleaned = String.replace(label, ~r/[^A-Za-z0-9_]/u, "_")
    if cleaned == "", do: "b", else: cleaned
  end

  # Splits IRI rejection into a named reason so a refusal receipt says *why*
  # rather than only *that*. `:iriref_forbidden_character` is the interesting
  # one -- it is the case where escaping would produce a parseable document
  # denoting an RFC 3987-illegal IRI, so refusal is the correct outcome.
  defp classify_iri(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:invalid, :not_utf8}
      not Regex.match?(@scheme_re, value) -> {:invalid, :not_absolute}
      Regex.match?(~r/[\s<>"{}|^`\\]/u, value) -> {:invalid, :iriref_forbidden_character}
      true -> :ok
    end
  end

  defp absolute_iri?(value) when is_binary(value), do: classify_iri(value) == :ok

  # -- verification --------------------------------------------------------

  defp canonical_term_set(triples) do
    triples
    |> Enum.reduce_while({:ok, MapSet.new()}, fn triple, {:ok, acc} ->
      case canonical_triple(triple) do
        {:ok, canonical} -> {:cont, {:ok, MapSet.put(acc, canonical)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_triple(%{subject: s, predicate: p, object: o}) do
    with {:ok, st} <- term(s, :subject),
         {:ok, pt} <- term(p, :predicate),
         {:ok, ot} <- term(o, :object) do
      {:ok, {normalize(st), normalize(pt), normalize(ot)}}
    end
  end

  defp canonical_triple(other), do: {:error, %{code: :serialize_malformed_triple, detail: other}}

  # Normalizes a term to a comparison form shared with RDF.ex's own model:
  # a plain literal and an explicit xsd:string literal denote the same RDF
  # term (RDF 1.1 S3.3), so both normalize to {:literal, value, :plain}.
  defp normalize({:iri, iri}), do: {:iri, iri}
  defp normalize({:bnode, label}), do: {:bnode, label}

  defp normalize({:literal, value, opts}) do
    cond do
      language = Keyword.get(opts, :language) ->
        {:literal, value, {:language, String.downcase(language)}}

      Keyword.get(opts, :datatype) == @xsd_string ->
        {:literal, value, :plain}

      datatype = Keyword.get(opts, :datatype) ->
        {:literal, value, {:datatype, datatype}}

      true ->
        {:literal, value, :plain}
    end
  end

  defp rdf_ex_triple_to_canonical({s, p, o}),
    do: {rdf_ex_term(s), rdf_ex_term(p), rdf_ex_term(o)}

  defp rdf_ex_term(%RDF.IRI{value: value}), do: {:iri, value}

  defp rdf_ex_term(%RDF.BlankNode{} = bnode),
    do: {:bnode, bnode |> to_string() |> String.replace_prefix("_:", "")}

  defp rdf_ex_term(%RDF.Literal{} = literal) do
    value = RDF.Literal.lexical(literal)
    datatype = literal |> RDF.Literal.datatype_id() |> to_string()

    cond do
      datatype == @rdf_lang_string ->
        {:literal, value, {:language, literal |> RDF.Literal.language() |> String.downcase()}}

      datatype == @xsd_string ->
        {:literal, value, :plain}

      true ->
        {:literal, value, {:datatype, datatype}}
    end
  end

  defp decode(serialized, :ntriples) do
    case RDF.NTriples.Decoder.decode(serialized) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        {:error, %{code: :serialize_unparseable_ntriples, reason: inspect(reason)}}
    end
  end

  defp decode(serialized, :turtle) do
    case RDF.Turtle.Decoder.decode(serialized) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        {:error, %{code: :serialize_unparseable_turtle, reason: inspect(reason)}}
    end
  end

  defp decode(_serialized, format),
    do: {:error, %{code: :serialize_unknown_format, detail: format}}
end
