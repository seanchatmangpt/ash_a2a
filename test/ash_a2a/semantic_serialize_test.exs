defmodule AshA2A.Semantic.SerializeTest do
  @moduledoc """
  Real, non-mocked coverage of the Elixir <-> RDF serialization boundary.

  Chicago-school throughout: no test double anywhere in this file. Every
  assertion is state-based on a real returned value -- a real serialized byte
  string, or a real `RDF.Graph` produced by the real `RDF.ex` decoder parsing
  this module's own output back. `RDF.ex` here is not a stub standing in for a
  parser; it *is* a real, independent parser implementation, which is exactly
  what makes it a useful differential oracle against our own encoder.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, Serialize, Vocabulary}

  defp triple(s, p, o), do: %{subject: s, predicate: p, object: o}

  defp round_trips?(triples, serialized, format) do
    match?({:ok, _}, Serialize.verify(triples, serialized, format: format))
  end

  describe "to_ntriples/1 basic shape" do
    test "emits one terminated line per triple" do
      triples = [
        triple("http://e/a", "http://e/p", {:iri, "http://e/b"}),
        triple("http://e/a", "http://e/q", {:literal, "hi"})
      ]

      assert {:ok, nt} = Serialize.to_ntriples(triples)

      assert nt ==
               "<http://e/a> <http://e/p> <http://e/b> .\n" <>
                 "<http://e/a> <http://e/q> \"hi\" .\n"
    end

    test "an empty triple list is the valid empty N-Triples document" do
      assert {:ok, ""} = Serialize.to_ntriples([])
    end

    test "a non-list is refused with a typed code, not raised" do
      assert {:error, %{code: :serialize_expected_triples}} = Serialize.to_ntriples(:nope)
    end

    test "a malformed triple map is refused with a typed code" do
      assert {:error, %{code: :serialize_malformed_triple}} =
               Serialize.to_ntriples([%{subject: "http://e/a"}])
    end
  end

  describe "literal escaping -- every escape survives a real RDF.ex parse-back" do
    # The exact values are asserted, not just "it round-trips", because a
    # wrong-but-self-consistent encoder would round-trip through its own
    # decoder happily. RDF.ex is a different implementation, so agreement
    # here is real evidence about the grammar, not about our own code.
    # `bs/1` builds the two-character sequence backslash + "u" without ever
    # writing a literal `\\u` escape in this source file, so the expectation
    # table cannot be mangled by an editor or tool that rewrites escapes.
    bs = fn rest -> <<92>> <> "u" <> rest end

    for {name, value, expected} <- [
          {"double quote", <<34>> <> "q" <> <<34>>, <<92, 34>> <> "q" <> <<92, 34>>},
          {"backslash", "back" <> <<92>> <> "slash", "back" <> <<92, 92>> <> "slash"},
          {"line feed", "nl" <> <<10>> <> "here", "nl" <> <<92>> <> "nhere"},
          {"carriage return", "cr" <> <<13>> <> "here", "cr" <> <<92>> <> "rhere"},
          {"tab", "tab" <> <<9>> <> "here", "tab" <> <<92>> <> "there"},
          {"backspace", "bs" <> <<8>> <> "here", "bs" <> <<92>> <> "bhere"},
          {"form feed", "ff" <> <<12>> <> "here", "ff" <> <<92>> <> "fhere"},
          {"nul byte", <<0>>, bs.("0000")},
          {"C0 controls", <<1, 2, 31>>, bs.("0001") <> bs.("0002") <> bs.("001F")},
          {"delete", <<0x7F>>, bs.("007F")},
          {"C1 control", <<0xC2, 0x85>>, bs.("0085")}
        ] do
      test "escapes #{name}" do
        triples = [triple("http://e/a", "http://e/p", {:literal, unquote(value)})]
        assert {:ok, nt} = Serialize.to_ntriples(triples)
        assert nt == "<http://e/a> <http://e/p> \"" <> unquote(expected) <> "\" .\n"
        assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)

        assert {:ok, ttl} = Serialize.to_turtle(triples)
        assert {:ok, 1} = Serialize.verify(triples, ttl, format: :turtle)
      end
    end

    for {name, value} <- [
          {"latin-1 supplement", "café"},
          {"CJK", "日本語"},
          {"astral plane emoji", "\u{1F680}"},
          {"combining marks", "ȩ́"}
        ] do
      test "emits #{name} raw (RDF 1.1 N-Triples is UTF-8) and it parses back identically" do
        triples = [triple("http://e/a", "http://e/p", {:literal, unquote(value)})]
        assert {:ok, nt} = Serialize.to_ntriples(triples)
        assert nt =~ unquote(value)
        assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
      end
    end

    test "a literal that is entirely control characters still round-trips" do
      value = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
      triples = [triple("http://e/a", "http://e/p", {:literal, value})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end
  end

  describe "typed and language-tagged literals" do
    test "typed literal carries ^^<datatype>" do
      xsd_integer = "http://www.w3.org/2001/XMLSchema#integer"
      triples = [triple("http://e/a", "http://e/p", {:literal, "42", datatype: xsd_integer})]

      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt == "<http://e/a> <http://e/p> \"42\"^^<#{xsd_integer}> .\n"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end

    test "language-tagged literal carries @tag and survives parse-back" do
      for tag <- ["en", "en-GB", "zh-Hant-TW"] do
        triples = [triple("http://e/a", "http://e/p", {:literal, "hi", language: tag})]
        assert {:ok, nt} = Serialize.to_ntriples(triples)
        assert nt == "<http://e/a> <http://e/p> \"hi\"@#{tag} .\n"
        assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
      end
    end

    test "an invalid language tag is refused rather than emitted" do
      assert {:error, %{code: :serialize_invalid_language_tag}} =
               Serialize.term({:literal, "x", language: "!!"}, :object)

      assert {:error, %{code: :serialize_invalid_language_tag}} =
               Serialize.term({:literal, "x", language: "toolongtagvalue"}, :object)
    end

    test "a plain literal and an explicit xsd:string literal denote the same RDF term" do
      xsd_string = "http://www.w3.org/2001/XMLSchema#string"
      plain = [triple("http://e/a", "http://e/p", {:literal, "hi"})]
      typed = [triple("http://e/a", "http://e/p", {:literal, "hi", datatype: xsd_string})]

      assert {:ok, plain_nt} = Serialize.to_ntriples(plain)
      assert {:ok, typed_nt} = Serialize.to_ntriples(typed)
      refute plain_nt == typed_nt

      # ...but each verifies against the other's intended triple set, because
      # RDF 1.1 S3.3 makes them the same term.
      assert {:ok, 1} = Serialize.verify(plain, typed_nt, format: :ntriples)
      assert {:ok, 1} = Serialize.verify(typed, plain_nt, format: :ntriples)
    end
  end

  describe "IRI handling" do
    test "a non-ASCII IRI is legal and is emitted raw" do
      triples = [triple("http://e/café", "http://e/p", {:literal, "v"})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt =~ "<http://e/café>"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end

    for {name, iri} <- [
          {"space", "http://e/a b"},
          {"open angle", "http://e/a<b"},
          {"quote", "http://e/a\"b"},
          {"braces", "http://e/a{b}"},
          {"pipe", "http://e/a|b"},
          {"caret", "http://e/a^b"},
          {"backtick", "http://e/a`b"},
          {"backslash", "http://e/a\\b"}
        ] do
      test "refuses an IRI containing a forbidden #{name} rather than escaping it into an illegal IRI" do
        assert {:error, %{code: :serialize_invalid_iri, reason: :iriref_forbidden_character}} =
                 Serialize.term(unquote(iri), :subject)
      end
    end

    test "a relative reference is refused in subject and predicate position" do
      assert {:error, %{code: :serialize_invalid_iri, reason: :not_absolute}} =
               Serialize.term("not-an-iri", :subject)

      assert {:error, %{code: :serialize_invalid_iri, reason: :not_absolute}} =
               Serialize.term("/relative/path", :predicate)
    end

    test "a literal is refused in subject and predicate position (no such RDF production)" do
      assert {:error, %{code: :serialize_literal_out_of_object_position, position: :predicate}} =
               Serialize.term({:literal, "x"}, :predicate)

      assert {:error, %{code: :serialize_literal_out_of_object_position, position: :subject}} =
               Serialize.term({:literal, "x"}, :subject)
    end
  end

  describe "bare-binary object inference (the documented heuristic, and its documented limit)" do
    test "an absolute-IRI-shaped bare binary infers as an IRI" do
      assert {:ok, {:iri, "urn:ash-a2a:semantic:node:e2"}} =
               Serialize.term("urn:ash-a2a:semantic:node:e2", :object)

      assert {:ok, {:iri, "http://e/b"}} = Serialize.term("http://e/b", :object)
    end

    test "everything else infers as a plain literal" do
      for value <- ["nowhere", "Alice", "Introduce Alice to Bob", "", "42", "a:b c"] do
        assert {:ok, {:literal, ^value, []}} = Serialize.term(value, :object)
      end
    end

    test "the documented false positive is real: an IRI-shaped literal infers as an IRI" do
      # Named in Serialize's @moduledoc rather than left to be discovered.
      assert {:ok, {:iri, "mailto:ops@example.com"}} =
               Serialize.term("mailto:ops@example.com", :object)

      # ...and the explicit form is the escape hatch that survives it.
      assert {:ok, {:literal, "mailto:ops@example.com", []}} =
               Serialize.term({:literal, "mailto:ops@example.com"}, :object)
    end
  end

  describe "blank nodes" do
    test "a blank node label is sanitized to the BLANK_NODE_LABEL grammar and parses back" do
      triples = [triple({:bnode, "weird label!"}, "http://e/p", {:bnode, "b0"})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt == "_:weird_label_ <http://e/p> _:b0 .\n"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end

    test "an empty blank node label never emits the illegal bare `_:`" do
      triples = [triple({:bnode, ""}, "http://e/p", {:literal, "v"})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt == "_:b <http://e/p> \"v\" .\n"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end

    test "a blank node is refused in predicate position" do
      assert {:error, %{code: :serialize_bnode_in_predicate}} =
               Serialize.term({:bnode, "b0"}, :predicate)
    end
  end

  describe "to_turtle/2" do
    test "emits a deterministic sorted @prefix block for only the prefixes actually used" do
      triples = [
        triple(
          "http://e/a",
          Vocabulary.expand("rdf:type"),
          {:iri, Vocabulary.expand("schema:Person")}
        )
      ]

      assert {:ok, ttl} = Serialize.to_turtle(triples)

      assert ttl ==
               "@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .\n" <>
                 "@prefix schema: <https://schema.org/> .\n" <>
                 "\n" <>
                 "<http://e/a> rdf:type schema:Person .\n"

      refute ttl =~ "@prefix owl:"
      assert {:ok, 1} = Serialize.verify(triples, ttl, format: :turtle)
    end

    test "compact: false emits every term as a full IRI and still parses back" do
      triples = [
        triple(
          "http://e/a",
          Vocabulary.expand("rdf:type"),
          {:iri, Vocabulary.expand("schema:Person")}
        )
      ]

      assert {:ok, ttl} = Serialize.to_turtle(triples, compact: false)
      refute ttl =~ "@prefix"

      assert ttl ==
               "<http://e/a> <#{Vocabulary.expand("rdf:type")}> <https://schema.org/Person> .\n"

      assert {:ok, 1} = Serialize.verify(triples, ttl, format: :turtle)
    end

    test "an IRI whose local part is not a safe PN_LOCAL falls back to a full <IRI>" do
      # "1bad" starts with a digit; "has.dots" and "has/slash" are outside the
      # conservative safe subset. Conservative compaction can only ever make
      # output more verbose, never ambiguous.
      for local <- ["1bad", "has.dots", "has/slash", "has:colon"] do
        triples = [triple("https://schema.org/" <> local, "http://e/p", {:literal, "v"})]
        assert {:ok, ttl} = Serialize.to_turtle(triples)
        assert ttl =~ "<https://schema.org/#{local}>"
        assert {:ok, 1} = Serialize.verify(triples, ttl, format: :turtle)
      end
    end

    test "default_prefixes/0 is the vocabulary registry plus xsd" do
      prefixes = Serialize.default_prefixes()
      assert prefixes["xsd"] == "http://www.w3.org/2001/XMLSchema#"

      for {prefix, namespace} <- Vocabulary.prefixes() do
        assert prefixes[prefix] == namespace
      end
    end

    test "a typed literal's datatype is compacted against xsd and parses back" do
      triples = [
        triple(
          "http://e/a",
          "http://e/p",
          {:literal, "42", datatype: "http://www.w3.org/2001/XMLSchema#integer"}
        )
      ]

      assert {:ok, ttl} = Serialize.to_turtle(triples)
      assert ttl =~ "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> ."
      assert ttl =~ ~s("42"^^xsd:integer)
      assert {:ok, 1} = Serialize.verify(triples, ttl, format: :turtle)
    end
  end

  describe "verify/3 -- the silent-truncation gate" do
    test "detects a dropped triple" do
      triples = [
        triple("http://e/a", "http://e/p", {:iri, "http://e/b"}),
        triple("http://e/a", "http://e/q", {:literal, "hi"})
      ]

      truncated = "<http://e/a> <http://e/p> <http://e/b> .\n"

      assert {:error, %{code: :serialize_round_trip_mismatch, expected_count: 2, actual_count: 1}} =
               Serialize.verify(triples, truncated, format: :ntriples)
    end

    test "detects an extra triple" do
      triples = [triple("http://e/a", "http://e/p", {:iri, "http://e/b"})]

      inflated =
        "<http://e/a> <http://e/p> <http://e/b> .\n<http://e/a> <http://e/p> <http://e/c> .\n"

      assert {:error, %{code: :serialize_round_trip_mismatch, unexpected: [_ | _]}} =
               Serialize.verify(triples, inflated, format: :ntriples)
    end

    test "detects a corrupted term while the triple count stays identical" do
      triples = [triple("http://e/a", "http://e/p", {:literal, "hi"})]
      corrupted = "<http://e/a> <http://e/p> \"HI\" .\n"

      assert {:error,
              %{
                code: :serialize_round_trip_mismatch,
                expected_count: 1,
                actual_count: 1,
                missing: [_],
                unexpected: [_]
              }} = Serialize.verify(triples, corrupted, format: :ntriples)
    end

    test "reports the RDF set size, so duplicate input triples collapse" do
      t = triple("http://e/a", "http://e/p", {:iri, "http://e/b"})
      triples = [t, t, t]

      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt |> String.split("\n", trim: true) |> length() == 3
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)
    end

    test "unparseable bytes are a typed refusal, not a silent pass" do
      triples = [triple("http://e/a", "http://e/p", {:literal, "hi"})]

      assert {:error, %{code: code}} = Serialize.verify(triples, "GARBAGE !!!", format: :ntriples)
      assert code in [:serialize_unparseable_ntriples, :serialize_round_trip_mismatch]
    end

    test "an unknown format is refused" do
      assert {:error, %{code: :serialize_unknown_format}} =
               Serialize.verify([], "", format: :jsonld)
    end
  end

  describe "RDF.ex 3.0.1 Turtle decoder defect (pinned, with evidence)" do
    # Found by AshA2A.Semantic.SerializePropertyTest, not by inspection.
    #
    # The oracle -- not this module's writer -- is wrong here: the Turtle and
    # N-Triples documents carry byte-identical literal syntax, the N-Triples
    # decoder reads it correctly, and only the Turtle decoder disagrees.
    # These tests exist so the defect is recorded rather than swallowed, and
    # so they fail loudly if a future `rdf` release fixes it (at which point
    # AshA2A.Semantic.CanonicalDigest's Turtle gate can be simplified).

    @escaped_quote <<92, 34>>
    @xsd_integer "http://www.w3.org/2001/XMLSchema#integer"

    defp turtle_lexical(document) do
      {:ok, graph} = RDF.Turtle.Decoder.decode(document)
      [{_s, _p, object}] = RDF.Graph.triples(graph)
      RDF.Literal.lexical(object)
    end

    defp ntriples_lexical(document) do
      {:ok, graph} = RDF.NTriples.Decoder.decode(document)
      [{_s, _p, object}] = RDF.Graph.triples(graph)
      RDF.Literal.lexical(object)
    end

    test "the installed rdf package is the version this defect was measured against" do
      assert Application.spec(:rdf, :vsn) |> to_string() == "3.0.1"
    end

    test "Turtle decoder unescapes correctly in a plain literal" do
      document = ~s(<http://e/a> <http://e/p> "x#{@escaped_quote}y" .)
      assert turtle_lexical(document) == "x" <> <<34>> <> "y"
    end

    test "Turtle decoder unescapes correctly in a language-tagged literal" do
      document = ~s(<http://e/a> <http://e/p> "x#{@escaped_quote}y"@en .)
      assert turtle_lexical(document) == "x" <> <<34>> <> "y"
    end

    test "Turtle decoder does NOT unescape in a typed literal -- the defect" do
      document = ~s(<http://e/a> <http://e/p> "x#{@escaped_quote}y"^^<#{@xsd_integer}> .)
      assert turtle_lexical(document) == "x" <> <<92, 34>> <> "y"
    end

    test "the N-Triples decoder reads that same byte-identical literal correctly" do
      document = ~s(<http://e/a> <http://e/p> "x#{@escaped_quote}y"^^<#{@xsd_integer}> .)
      assert ntriples_lexical(document) == "x" <> <<34>> <> "y"
    end

    test "our Turtle writer emits the same literal syntax as our N-Triples writer" do
      triples = [
        triple(
          "http://e/a",
          "http://e/p",
          {:literal, "x" <> <<34>> <> "y", datatype: @xsd_integer}
        )
      ]

      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert {:ok, ttl} = Serialize.to_turtle(triples, compact: false)
      assert nt == ttl

      # ...so the mismatch below is the oracle disagreeing with itself across
      # two of its own decoders over one identical byte string.
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)

      assert {:error, %{code: :serialize_round_trip_mismatch}} =
               Serialize.verify(triples, ttl, format: :turtle)
    end
  end

  describe "from_json/1 -- graphlaw result payloads" do
    test "an {\"error\": ...} payload becomes a typed refusal even though it is valid JSON" do
      assert {:error, %{code: :graphlaw_error, detail: "boom"}} =
               Serialize.from_json(~s({"error":"boom"}))
    end

    test "a real run_hooks payload decodes to a map" do
      payload = ~s({"status":"ADMITTED","verdicts":[],"receipts":[],"schedule":[]})

      assert {:ok,
              %{"status" => "ADMITTED", "verdicts" => [], "receipts" => [], "schedule" => []}} =
               Serialize.from_json(payload)
    end

    test "non-JSON and non-object payloads are typed refusals" do
      assert {:error, %{code: :graphlaw_non_json}} = Serialize.from_json("not json")
      assert {:error, %{code: :graphlaw_unexpected_payload}} = Serialize.from_json("[1,2]")
      assert {:error, %{code: :graphlaw_non_binary_payload}} = Serialize.from_json(:atom)
    end
  end

  describe "over the real AshA2A.Semantic.Ontology" do
    defp admitted_ir do
      %IR{
        source_id: "src-1",
        standing: :admitted,
        authority: :none,
        entities: [
          %{"id" => "e1", "kind" => "entity", "type" => "schema:Person", "label" => "Alice"},
          %{"id" => "e2", "kind" => "entity", "type" => "schema:Person", "label" => "Bob"}
        ],
        relations: [
          %{
            "id" => "r1",
            "kind" => "relation",
            "subject" => "e1",
            "predicate" => "schema:knows",
            "object" => "e2"
          }
        ],
        goals: [
          %{
            "id" => "g1",
            "kind" => "goal",
            "description" => "Introduce \"Alice\" to Bob\nsecond\tline"
          }
        ]
      }
    end

    test "a real Ontology serializes to N-Triples and Turtle that both parse back exactly" do
      assert {:ok, ontology} = Ontology.from_ir(admitted_ir())
      assert {:ok, nt} = Serialize.to_ntriples(ontology)
      assert {:ok, ttl} = Serialize.to_turtle(ontology)

      assert {:ok, count} = Serialize.verify(ontology, nt, format: :ntriples)
      assert {:ok, ^count} = Serialize.verify(ontology, ttl, format: :turtle)
      assert count == length(ontology.triples)
      assert count > 0
    end

    test "a goal description containing quotes, a newline and a tab survives both serializations" do
      assert {:ok, ontology} = Ontology.from_ir(admitted_ir())
      assert {:ok, nt} = Serialize.to_ntriples(ontology)

      assert nt =~ ~S("Introduce \"Alice\" to Bob\nsecond\tline")
      assert round_trips?(ontology.triples, nt, :ntriples)

      assert {:ok, ttl} = Serialize.to_turtle(ontology)
      assert round_trips?(ontology.triples, ttl, :turtle)
    end

    test "Ontology's untyped relation object splits correctly: known id -> IRI, unknown -> literal" do
      ir = %{
        admitted_ir()
        | relations:
            admitted_ir().relations ++
              [
                %{
                  "id" => "r2",
                  "kind" => "relation",
                  "subject" => "e1",
                  "predicate" => "schema:knows",
                  "object" => "nowhere"
                }
              ]
      }

      assert {:ok, ontology} = Ontology.from_ir(ir)
      assert {:ok, nt} = Serialize.to_ntriples(ontology)

      assert nt =~ "<https://schema.org/knows> <urn:ash-a2a:semantic:node:e2> ."
      assert nt =~ ~s(<https://schema.org/knows> "nowhere" .)
      assert round_trips?(ontology.triples, nt, :ntriples)
    end

    test "serialization is deterministic -- identical input, byte-identical output" do
      assert {:ok, ontology} = Ontology.from_ir(admitted_ir())
      assert {:ok, first} = Serialize.to_ntriples(ontology)
      assert {:ok, second} = Serialize.to_ntriples(ontology)
      assert first == second

      assert {:ok, ttl_first} = Serialize.to_turtle(ontology)
      assert {:ok, ttl_second} = Serialize.to_turtle(ontology)
      assert ttl_first == ttl_second
    end
  end
end
