defmodule AshA2A.Semantic.SerializePropertyTest do
  @moduledoc """
  Real property coverage of the Elixir <-> RDF serialization boundary, using
  the real `StreamData` dependency already declared in this project's `mix.exs`
  (same real generator machinery as `test/ash_a2a_property_fuzz_test.exs`).

  Chicago-school: no test double anywhere. The oracle is the real `RDF.ex`
  decoder -- a genuinely separate implementation of the RDF 1.1 N-Triples and
  Turtle grammars from `AshA2A.Semantic.Serialize`'s own encoder. Agreement
  between two independent implementations over generated adversarial input is
  real evidence about the grammar; agreement between an encoder and its own
  decoder would be evidence about nothing.

  Every generated literal draws from a character set deliberately loaded with
  the bytes that break naive serializers: `"`, `\\`, LF, CR, TAB, NUL, other
  C0/C1 controls, DEL, and multi-byte UTF-8 including an astral-plane
  codepoint.

  Properties asserted:

    1. **N-Triples round-trip fidelity** -- re-parsing our own output with
       `RDF.NTriples.Decoder` yields exactly the intended RDF term set.
    2. **Turtle round-trip fidelity** -- same, via `RDF.Turtle.Decoder`.
    3. **Cross-format agreement** -- the Turtle and N-Triples serializations of
       the same triples decode to the same `RDF.Graph`, checked against RDF.ex
       directly rather than through our own `verify/3`.
    4. **Determinism** -- identical input yields byte-identical output.
    5. **Line structure** -- N-Triples emits exactly one line per input triple
       and no raw control character ever escapes into the document.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.Semantic.Serialize

  # Deliberately hostile character set, built from integer codepoints so no
  # literal escape sequence appears in this source file.
  @nasty_codepoints [
    34,
    92,
    10,
    13,
    9,
    8,
    12,
    0,
    1,
    31,
    0x7F,
    0x85,
    ?a,
    ?Z,
    ?0,
    ?\s,
    ?<,
    ?>,
    ?^,
    ?:,
    0x00E9,
    0x65E5,
    0x1F680
  ]

  defp literal_text do
    gen all(codes <- list_of(member_of(@nasty_codepoints), max_length: 24)) do
      Enum.reduce(codes, "", fn code, acc -> acc <> <<code::utf8>> end)
    end
  end

  defp iri_segment do
    gen all(
          chars <- list_of(member_of(~c"abcdefGHIJ0123456789-_.~"), min_length: 1, max_length: 12)
        ) do
      to_string(chars)
    end
  end

  defp iri do
    gen all(
          base <-
            member_of(["http://example.org/", "https://schema.org/", "urn:ash-a2a:semantic:"]),
          segment <- iri_segment()
        ) do
      base <> segment
    end
  end

  defp bnode_label do
    gen all(chars <- list_of(member_of(~c"abAB01_"), min_length: 1, max_length: 8)) do
      to_string(chars)
    end
  end

  defp language_tag, do: member_of(["en", "fr", "en-GB", "zh-Hant-TW", "de-DE"])

  defp datatype_iri do
    member_of(
      Enum.map(
        ~w(integer decimal boolean dateTime double anyURI),
        &("http://www.w3.org/2001/XMLSchema#" <> &1)
      )
    )
  end

  # Escape-free text, for the one generator position where the RDF.ex Turtle
  # oracle is known-defective. Not a weakening of the N-Triples properties --
  # `literal_text/0` above is used unrestricted there.
  defp escape_free_text do
    gen all(chars <- list_of(member_of(~c"abcXYZ019 -_."), max_length: 20)) do
      to_string(chars)
    end
  end

  defp object_term(typed_text) do
    one_of([
      map(iri(), &{:iri, &1}),
      map(bnode_label(), &{:bnode, &1}),
      map(literal_text(), &{:literal, &1}),
      map({literal_text(), language_tag()}, fn {v, t} -> {:literal, v, language: t} end),
      map({typed_text, datatype_iri()}, fn {v, d} -> {:literal, v, datatype: d} end)
    ])
  end

  defp subject_term, do: one_of([map(iri(), &{:iri, &1}), map(bnode_label(), &{:bnode, &1})])

  defp triple_gen(typed_text) do
    gen all(s <- subject_term(), p <- iri(), o <- object_term(typed_text)) do
      %{subject: s, predicate: p, object: o}
    end
  end

  # Full-strength graphs: typed literals draw from the hostile character set
  # too. Used for every property whose oracle is the sound N-Triples decoder.
  defp graph_gen(max \\ 12), do: list_of(triple_gen(literal_text()), max_length: max)

  # Turtle-safe graphs: identical except that typed-literal *text* is
  # escape-free, working around the measured RDF.ex 3.0.1 Turtle decoder
  # defect (it does not unescape ECHAR/UCHAR inside a `^^`-typed literal --
  # pinned with evidence in AshA2A.Semantic.SerializeTest's "RDF.ex 3.0.1
  # Turtle decoder defect" block). The defect is in the oracle, not in
  # Serialize's writer: both writers emit byte-identical literal syntax and
  # the N-Triples decoder reads it correctly.
  defp turtle_safe_graph_gen(max \\ 12),
    do: list_of(triple_gen(escape_free_text()), max_length: max)

  defp decode!(document, :ntriples), do: RDF.NTriples.Decoder.decode(document)
  defp decode!(document, :turtle), do: RDF.Turtle.Decoder.decode(document)

  property "1. every generated graph round-trips through N-Triples with exact term fidelity" do
    check all(triples <- graph_gen(), max_runs: 300) do
      assert {:ok, nt} = Serialize.to_ntriples(triples)

      assert {:ok, count} = Serialize.verify(triples, nt, format: :ntriples),
             "N-Triples round-trip lost or corrupted a term for: #{inspect(triples)}"

      assert count ==
               triples
               |> Enum.map(&{&1.subject, &1.predicate, &1.object})
               |> Enum.uniq()
               |> length()
    end
  end

  property "2. every generated graph round-trips through Turtle with exact term fidelity" do
    check all(triples <- turtle_safe_graph_gen(), max_runs: 300) do
      assert {:ok, ttl} = Serialize.to_turtle(triples)

      assert {:ok, _count} = Serialize.verify(triples, ttl, format: :turtle),
             "Turtle round-trip lost or corrupted a term for: #{inspect(triples)}"
    end
  end

  property "3. Turtle and N-Triples serializations of the same graph decode to the same RDF.Graph" do
    # Checked against RDF.ex directly, not through Serialize.verify/3, so this
    # property cannot be satisfied by a bug shared between our encoder and our
    # own comparison logic.
    check all(triples <- turtle_safe_graph_gen(), max_runs: 200) do
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert {:ok, ttl} = Serialize.to_turtle(triples)

      assert {:ok, nt_graph} = decode!(nt, :ntriples)
      assert {:ok, ttl_graph} = decode!(ttl, :turtle)

      assert MapSet.new(RDF.Graph.triples(nt_graph)) == MapSet.new(RDF.Graph.triples(ttl_graph)),
             "Turtle and N-Triples disagreed for: #{inspect(triples)}"
    end
  end

  property "4. serialization is deterministic in both formats" do
    check all(triples <- graph_gen(), max_runs: 200) do
      assert {:ok, nt_a} = Serialize.to_ntriples(triples)
      assert {:ok, nt_b} = Serialize.to_ntriples(triples)
      assert nt_a == nt_b

      assert {:ok, ttl_a} = Serialize.to_turtle(triples)
      assert {:ok, ttl_b} = Serialize.to_turtle(triples)
      assert ttl_a == ttl_b
    end
  end

  property "5. N-Triples emits one line per triple and never leaks a raw control character" do
    check all(triples <- graph_gen(), max_runs: 300) do
      assert {:ok, nt} = Serialize.to_ntriples(triples)

      lines = String.split(nt, "\n", trim: true)
      assert length(lines) == length(triples)

      for line <- lines do
        assert String.ends_with?(line, " .")

        refute Enum.any?(String.to_charlist(line), &(&1 < 0x20 or &1 == 0x7F)),
               "raw control character leaked into: #{inspect(line)}"
      end
    end
  end

  property "6. a bare-binary object is inferred consistently with the documented rule" do
    check all(text <- literal_text(), max_runs: 200) do
      assert {:ok, term} = Serialize.term(text, :object)

      case term do
        {:iri, ^text} ->
          # Only reachable for IRI-shaped text: a scheme, and no character
          # the IRIREF production forbids.
          assert Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.\-]*:/, text)
          refute Regex.match?(~r/[\s<>"{}|^`\\]/u, text)

        {:literal, ^text, []} ->
          :ok
      end
    end
  end
end
