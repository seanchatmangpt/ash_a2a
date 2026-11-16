# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Direct ash_a2a Suite: Task Lifecycle Store
# Target File 3 of Worker 09
# Consolidated from 14 source files:
#   - test/ash_a2a/semantic_schema_test.exs
#   - test/ash_a2a/semantic_select_test.exs
#   - test/ash_a2a/semantic_serialize_bnode_injectivity_test.exs
#   - test/ash_a2a/semantic_serialize_property_test.exs
#   - test/ash_a2a/semantic_serialize_test.exs
#   - test/ash_a2a/semantic_source_test.exs
#   - test/ash_a2a/semantic_standing_test.exs
#   - test/ash_a2a/semantic_synthesis_test.exs
#   - test/ash_a2a/semantic_vocabulary_test.exs
#   - test/ash_a2a/skill_test.exs
#   - test/ash_a2a/soak_cross_product_test.exs
#   - test/ash_a2a/task_lifecycle_state_machine_test.exs
#   - test/ash_a2a/task_store_ekv_test.exs
#   - test/ash_a2a/w608_map_update_court_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/semantic_schema_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.SchemaTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Schema}

  describe "extraction/0" do
    setup do
      {:ok, schema: Schema.extraction()}
    end

    test "additionalProperties is false", %{schema: schema} do
      assert schema["additionalProperties"] == false
    end

    test "properties keys are exactly IR fields plus authority", %{schema: schema} do
      expected = MapSet.new(Enum.map(IR.fields(), &Atom.to_string/1) ++ ["authority"])
      actual = schema["properties"] |> Map.keys() |> MapSet.new()
      assert actual == expected
    end

    test "required is exactly IR fields plus authority", %{schema: schema} do
      expected = MapSet.new(Enum.map(IR.fields(), &Atom.to_string/1) ++ ["authority"])
      actual = MapSet.new(schema["required"])
      assert actual == expected
    end

    test "authority property is a string enum of none", %{schema: schema} do
      assert schema["properties"]["authority"] == %{
               "type" => "string",
               "enum" => ["none"]
             }
    end

    test "each IR field property is an array of the shared assertion schema", %{schema: schema} do
      field_strings = Enum.map(IR.fields(), &Atom.to_string/1)

      assertion_schemas =
        Enum.map(field_strings, fn field ->
          entry = schema["properties"][field]
          assert entry["type"] == "array"
          assert is_map(entry["items"])
          entry["items"]
        end)

      # every field's nested assertion schema is identical
      assert Enum.uniq(assertion_schemas) |> length() == 1

      Enum.each(assertion_schemas, fn item_schema ->
        assert %{"type" => "array", "items" => ^item_schema} =
                 schema["properties"][hd(field_strings)]
      end)
    end

    test "shared assertion schema has the load-bearing mode enum and required fields", %{
      schema: schema
    } do
      assertion = schema["properties"]["goals"]["items"]

      assert assertion["properties"]["mode"]["enum"] == ["described", "denied", "unknown"]
      assert assertion["required"] == ["id", "kind", "source_quote"]
    end

    test "assertion schema is identical regardless of which field it is read from", %{
      schema: schema
    } do
      for field <- Enum.map(IR.fields(), &Atom.to_string/1) do
        assert schema["properties"][field]["items"] == schema["properties"]["goals"]["items"]
      end
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/semantic_select_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.SelectTest do
  @moduledoc """
  RFC-SA2A-001 S25: SELECT chooses among lawful possibilities and MUST NOT
  perform consequential external mutation.

  The "no consequential external mutation" claim is checked against the
  **real compiled BEAM's own import table** (`:beam_lib.chunks(beam,
  [:imports])`), not against a grep of the source and not against a mock
  that records calls. The import table is the exhaustive list of external
  functions the module's compiled code can call; a module whose import table
  contains no `AshA2A.CommandBus` entry provably cannot reach the
  consequence boundary, whatever its source looks like.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{PlanPackage, Select}
  alias AshA2A.Test.SA2APlanFixture, as: Fixture

  defp package(overrides) do
    {projection, _ontology} = Fixture.projection()

    {:ok, pkg} =
      PlanPackage.from_projection(projection, "planner", Fixture.strict_opts(overrides))

    pkg
  end

  # Real module-level structural fact, read out of the compiled .beam file on
  # disk. Returns the list of `{module, function, arity}` this module's
  # compiled code can call externally.
  defp imports(module) do
    {:ok, path} = AshA2A.BeamFile.path(module)
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(path, [:imports])
    imports
  end

  defp imported_modules(module) do
    module |> imports() |> Enum.map(fn {mod, _fun, _arity} -> mod end) |> Enum.uniq()
  end

  describe "S25 -- SELECT performs no consequential external mutation" do
    test "the compiled module's real import table reaches no consequence boundary" do
      modules = imported_modules(Select)

      # Sanity: the check is capable of seeing anything at all.
      assert AshA2A.Semantic.PlanPackage in modules

      forbidden = [
        AshA2A.CommandBus,
        AshA2A.ReceiptStore,
        AshA2A.ReceiptOutbox,
        AshA2A.Receipt,
        AshA2A.Authority,
        AshA2A.KillSwitch,
        Ash,
        Ecto.Repo,
        :file,
        :os
      ]

      assert Enum.filter(forbidden, &(&1 in modules)) == []
    end

    test "the module exposes no DO-shaped function at all" do
      exported = Select.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      for banned <- [:execute, :run, :dispatch, :do_select, :commit, :apply_plan] do
        refute banned in exported
      end

      assert :select in exported
    end

    test "a selection is candidate-standing and authority-free" do
      packages = [package(max_depth: 3), package(max_depth: 4)]
      assert {:ok, selection} = Select.select(packages, & &1.max_depth)

      assert selection.standing == :candidate
      assert selection.authority == :none
      refute Map.has_key?(selection, :authority_grant)
    end
  end

  describe "choosing among lawful possibilities" do
    test "the lowest-cost candidate wins and the rest are recorded as rejected" do
      cheap = package(max_depth: 2)
      mid = package(max_depth: 5)
      dear = package(max_depth: 9)

      assert {:ok, selection} =
               Select.select([dear, cheap, mid], & &1.max_depth,
                 selector_identity: "test-selector"
               )

      assert selection.chosen.max_depth == 2
      assert selection.chosen_digest == cheap.plan_digest

      assert selection.considered_digests == [
               cheap.plan_digest,
               mid.plan_digest,
               dear.plan_digest
             ]

      assert selection.rejected_digests == [mid.plan_digest, dear.plan_digest]
      assert selection.selector_identity == "test-selector"
      assert selection.selection_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "selection is deterministic regardless of the order candidates arrive in" do
      a = package(max_depth: 3)
      b = package(max_depth: 7)
      c = package(max_fan_out: 2, max_depth: 3)

      # a and c tie on the scorer; the plan_digest tie-break is order-free.
      {:ok, one} = Select.select([a, b, c], & &1.max_depth)
      {:ok, two} = Select.select([c, b, a], & &1.max_depth)
      {:ok, three} = Select.select([b, c, a], & &1.max_depth)

      assert one.chosen_digest == two.chosen_digest
      assert two.chosen_digest == three.chosen_digest
      assert one.selection_digest == two.selection_digest
      assert two.selection_digest == three.selection_digest
    end

    test "a selection over a different candidate set is distinguishable even when it chose the same package" do
      winner = package(max_depth: 1)
      other = package(max_depth: 4)

      {:ok, narrow} = Select.select([winner], & &1.max_depth)
      {:ok, wide} = Select.select([winner, other], & &1.max_depth)

      assert narrow.chosen_digest == wide.chosen_digest
      refute narrow.selection_digest == wide.selection_digest
    end

    test "an empty candidate set is refused" do
      assert {:error, %{code: :selection_no_candidates}} = Select.select([], & &1.max_depth)
    end

    test "a tampered candidate refuses the whole selection, naming its index" do
      good = package(max_depth: 2)
      tampered = %{package(max_depth: 3) | max_depth: 999}

      assert {:error, %{code: :selection_candidate_unverifiable, detail: detail}} =
               Select.select([good, tampered], & &1.max_depth)

      assert detail.index == 1
      assert detail.refusal.code == :plan_package_manual_edit_not_canonical
    end

    test "a non-numeric scorer result is a typed refusal, not a crash" do
      assert {:error, %{code: :selection_scorer_invalid, detail: detail}} =
               Select.select([package(max_depth: 2)], fn _pkg -> :cheap end)

      assert detail.returned == :cheap
    end

    test "a strict receiver refuses to select among permissively-built plans" do
      {projection, _ontology} = Fixture.projection()

      {:ok, loose} =
        PlanPackage.from_projection(
          projection,
          "planner",
          Fixture.strict_opts(profile: :permissive, max_parallelism: nil)
        )

      # Without a profile demand, the loose plan is selectable.
      assert {:ok, _selection} = Select.select([loose], fn _pkg -> 1 end)

      # With one, it is refused -- and the refusal names which candidate.
      assert {:error, %{code: :selection_candidate_profile_violation, detail: detail}} =
               Select.select([loose], fn _pkg -> 1 end, profile: :strict)

      assert detail.index == 0
      assert detail.profile == :strict
      assert :max_parallelism in detail.refusal.detail.missing
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/semantic_serialize_bnode_injectivity_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticSerializeBnodeInjectivityTest do
  @moduledoc """
  Regression cover for the non-injective blank-node sanitization defect in
  `AshA2A.Semantic.Serialize`.

  The defect, as reproduced before the fix:

      to_ntriples([%{subject: {:bnode, "x-1"}, ...}])  -> _:x_1 ...
      to_ntriples([%{subject: {:bnode, "x.1"}, ...}])  -> _:x_1 ...
      to_ntriples([%{subject: {:bnode, "x 1"}, ...}])  -> _:x_1 ...
      to_ntriples([%{subject: {:bnode, "x!1"}, ...}])  -> _:x_1 ...
      to_ntriples([%{subject: {:bnode, ""},    ...}])  -> _:b   ...
      to_ntriples([%{subject: {:bnode, "b"},   ...}])  -> _:b   ...

  so a two-triple graph whose subjects were `_:x-1` and `_:x.1` serialized to
  one repeated line, `verify/3` reported `{:ok, 1}` without complaint because
  it applied the same lossy map to its own expectation, and the two distinct
  graphs produced one digest.

  Every collaborator here is real: this module's own encoder, and the real
  `RDF.ex` 3.0.1 decoder as the independent parse-back oracle.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.Semantic.Serialize

  @p "http://e/p"

  defp triple(label), do: %{subject: {:bnode, label}, predicate: @p, object: {:literal, "v"}}

  defp line(label) do
    {:ok, nt} = Serialize.to_ntriples([triple(label)])
    nt
  end

  describe "the verifier's minimal reproducing input" do
    test "the four labels that collapsed onto x_1 now serialize to four distinct documents" do
      collided = ["x-1", "x.1", "x 1", "x!1"]
      rendered = Enum.map(collided, &line/1)

      assert length(Enum.uniq(rendered)) == 4,
             "expected 4 distinct serializations, got: #{inspect(rendered)}"
    end

    test "the empty label no longer collides with the genuine label \"b\"" do
      refute line("") == line("b")
    end

    test "two distinct blank-node subjects survive as two triples, not one" do
      merging = [triple("x-1"), triple("x.1")]

      {:ok, nt} = Serialize.to_ntriples(merging)

      assert nt == ~s|_:x-1 <http://e/p> "v" .\n_:x.1 <http://e/p> "v" .\n|

      # The parse-back gate is the thing that was blind. It now witnesses two.
      assert {:ok, 2} = Serialize.verify(merging, nt)
    end

    test "the two graphs that shared one digest now have different bytes" do
      a = line("x-1")
      b = line("x.1")

      refute a == b
      refute :crypto.hash(:sha256, a) == :crypto.hash(:sha256, b)
    end
  end

  describe "labels already legal under BLANK_NODE_LABEL are not touched" do
    for label <- ["x-1", "x.1", "b1", "a.b.c", "7", "日本"] do
      test "#{inspect(label)} passes through verbatim" do
        assert Serialize.encode_bnode_label(unquote(label)) == unquote(label)
      end
    end

    test "an underscore is the one legal character that is still rewritten, and only by doubling" do
      # `_` is reserved as the escape introducer, so it must double for the
      # encoding to stay decodable. Doubling is injective and the result is
      # still a legal label -- unlike the old map, which sent every
      # non-word character *to* `_` and lost them all.
      assert Serialize.encode_bnode_label("x_y") == "x__y"
      assert Serialize.encode_bnode_label("_7") == "__7"
      assert Serialize.decode_bnode_label("x__y") == "x_y"
      assert Serialize.decode_bnode_label("__7") == "_7"
    end
  end

  describe "genuinely illegal labels are escaped reversibly, not flattened" do
    test "a space becomes a reversible escape" do
      assert Serialize.encode_bnode_label("x 1") == "x_u00201"
      assert Serialize.decode_bnode_label("x_u00201") == "x 1"
    end

    test "the empty label maps to a sequence no non-empty label can produce" do
      assert Serialize.encode_bnode_label("") == "_e"
      assert Serialize.decode_bnode_label("_e") == ""
      refute Serialize.encode_bnode_label("_e") == "_e"
    end

    test "a leading or trailing dot is illegal at the edge and is escaped there" do
      assert Serialize.encode_bnode_label(".x") == "_u002Ex"
      assert Serialize.encode_bnode_label("x.") == "x_u002E"
      # ... but legal in the middle, so it stays.
      assert Serialize.encode_bnode_label("x.y") == "x.y"
    end
  end

  describe "injectivity" do
    test "decode is the left inverse of encode over the collision set and its escapes" do
      for label <- ["x-1", "x.1", "x 1", "x!1", "", "b", "_e", "x_u00201", "__", "_", ".", "."] do
        assert Serialize.decode_bnode_label(Serialize.encode_bnode_label(label)) == label,
               "round trip failed for #{inspect(label)}"
      end
    end

    property "decode(encode(label)) == label for generated labels" do
      check all(label <- label_generator()) do
        assert Serialize.decode_bnode_label(Serialize.encode_bnode_label(label)) == label
      end
    end

    property "distinct labels never share an encoding" do
      check all(a <- label_generator(), b <- label_generator()) do
        if a == b do
          assert Serialize.encode_bnode_label(a) == Serialize.encode_bnode_label(b)
        else
          refute Serialize.encode_bnode_label(a) == Serialize.encode_bnode_label(b),
                 "#{inspect(a)} and #{inspect(b)} collided"
        end
      end
    end

    property "every encoding is a label the real RDF.ex parser reads back unchanged" do
      check all(label <- label_generator()) do
        triples = [triple(label)]
        {:ok, nt} = Serialize.to_ntriples(triples)

        assert {:ok, 1} = Serialize.verify(triples, nt),
               "round trip through the real parser failed for #{inspect(label)}: #{inspect(nt)}"
      end
    end

    property "two distinct labels always survive as two triples through the real parser" do
      # Distinctness is constructed, not filtered: at small generation sizes
      # both draws are frequently "", so a `a != b` filter exhausts
      # StreamData's consecutive-filter budget (FilterTooNarrowError, seed
      # 327629). An equal draw becomes the adversarial prefix pair `a`/`a_`;
      # every distinct pair the filter admitted is still generated.
      check all(
              a <- label_generator(),
              b0 <- label_generator(),
              b = if(a == b0, do: a <> "_", else: b0)
            ) do
        triples = [triple(a), triple(b)]
        {:ok, nt} = Serialize.to_ntriples(triples)

        assert {:ok, 2} = Serialize.verify(triples, nt),
               "#{inspect(a)} and #{inspect(b)} merged: #{inspect(nt)}"
      end
    end
  end

  # Deliberately biased toward the characters that broke the old map: the
  # ASCII punctuation it flattened to `_`, the `_` it could not distinguish
  # from a flattened character, the `.` whose legality is position-dependent,
  # and the empty string.
  defp label_generator do
    StreamData.one_of([
      StreamData.constant(""),
      StreamData.string(Enum.concat([?a..?f, ?0..?2, [?-, ?., ?_, ?!, ?\s, ?:, ?/, ?#]]),
        min_length: 0,
        max_length: 6
      ),
      StreamData.string(:printable, min_length: 0, max_length: 6)
    ])
  end
end

# --- SECTION 4: Original test/ash_a2a/semantic_serialize_property_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

# --- SECTION 5: Original test/ash_a2a/semantic_serialize_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  # SUPERSEDED (v26.9.16 serialization-misc fixes): the two expectations here
  # previously pinned the lossy `[^A-Za-z0-9_] -> _` sanitization, i.e. they
  # encoded the non-injectivity defect as the specification -- `"weird
  # label!"` was asserted to become `weird_label_`, which is the same image
  # as `"weird_label_"`, `"weird-label-"` and `"weird.label."`, and the empty
  # label was asserted to become `b`, colliding with a real label `b`. They
  # now pin the injective escaping that replaced it. Injectivity itself is
  # proved in
  # `test/ash_a2a/semantic_serialize_bnode_injectivity_test.exs`.
  describe "blank nodes" do
    test "a blank node label is injectively escaped to the BLANK_NODE_LABEL grammar and parses back" do
      triples = [triple({:bnode, "weird label!"}, "http://e/p", {:bnode, "b0"})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt == "_:weird_u0020label_u0021 <http://e/p> _:b0 .\n"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)

      # The labels the old map merged onto `weird_label_` stay distinct.
      others = ["weird_label_", "weird-label-", "weird.label.", "weird_u0020label_u0021"]

      encodings = Enum.map(["weird label!" | others], &Serialize.encode_bnode_label/1)
      assert length(Enum.uniq(encodings)) == length(encodings)
    end

    test "an empty blank node label never emits the illegal bare `_:`, and never collides" do
      triples = [triple({:bnode, ""}, "http://e/p", {:literal, "v"})]
      assert {:ok, nt} = Serialize.to_ntriples(triples)
      assert nt == "_:_e <http://e/p> \"v\" .\n"
      assert {:ok, 1} = Serialize.verify(triples, nt, format: :ntriples)

      # `_e` is unreachable from any non-empty label, so the empty label
      # cannot collide with a real one -- including the literal label "_e".
      refute Serialize.encode_bnode_label("_e") == Serialize.encode_bnode_label("")
      refute Serialize.encode_bnode_label("b") == Serialize.encode_bnode_label("")
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

# --- SECTION 6: Original test/ash_a2a/semantic_source_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.SourceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Source

  describe "new/2" do
    test "defaults media_type, provenance, observed_at and produces a 64-char lowercase hex id" do
      source = Source.new("hello world")

      assert source.text == "hello world"
      assert source.media_type == "text/plain"
      assert source.provenance == %{}
      assert source.observed_at == nil
      assert is_binary(source.id)
      assert String.length(source.id) == 64
      assert source.id == String.downcase(source.id)
      assert source.id =~ ~r/^[0-9a-f]{64}$/
    end

    test "identical text/media_type/provenance produce the same id" do
      opts = [media_type: "text/markdown", provenance: %{origin: "test"}]

      source_a = Source.new("same content", opts)
      source_b = Source.new("same content", opts)

      assert source_a.id == source_b.id
    end

    test "an explicit :id opt overrides fingerprinting exactly" do
      source = Source.new("some text", id: "explicit-id-123")

      assert source.id == "explicit-id-123"
    end

    test "an explicit non-string atom :id is coerced via to_string/1" do
      source = Source.new("some text", id: :my_atom_id)

      assert source.id == "my_atom_id"
    end

    test "different text produces a different id" do
      opts = [media_type: "text/plain", provenance: %{}]

      source_a = Source.new("text one", opts)
      source_b = Source.new("text two", opts)

      refute source_a.id == source_b.id
    end

    test "different provenance produces a different id" do
      source_a = Source.new("same text", provenance: %{origin: "a"})
      source_b = Source.new("same text", provenance: %{origin: "b"})

      refute source_a.id == source_b.id
    end
  end

  describe "uri/1" do
    test "returns urn:ash-a2a:source: prefixed id" do
      source = Source.new("some text", id: "abc123")

      assert Source.uri(source) == "urn:ash-a2a:source:abc123"
    end
  end
end

# --- SECTION 7: Original test/ash_a2a/semantic_standing_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticStandingTest.LaunderingStruct do
  @moduledoc """
  A real struct carrying a field named after one of the S6 forbidden inference
  sources. Not a mock of anything -- it is a plain struct, used to prove that
  the recursive scan descends into struct fields instead of raising on them.
  """
  defstruct [:label, :hook_fired]
end

defmodule AshA2A.SemanticStandingTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Standing` (RFC-SA2A-001 S6/S41).

  Every test drives the real `transition/3` over a real
  `AshA2A.Semantic.Envelope` struct and asserts on the real returned
  envelope or the real returned `AshA2A.Semantic.Refusal` struct. Nothing
  is mocked and nothing is stubbed -- the whole lifecycle is pure Elixir
  and runnable in-process, so a double would only test this file's own
  model of it.

  The `@evidence` table below is real evidence in the shape each step
  demands; the "full walk" test drives all sixteen transitions end to end
  and asserts on the resulting standing and history, not on call counts.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Envelope, Refusal, Standing}

  @evidence %{
    received: %{transport: "a2a/https", received_at: "2026-09-16T00:00:00Z"},
    parsed: %{media_type: "text/turtle", triple_count: 42},
    identified: %{
      graph_digest: "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d",
      digest_algorithm: "rdfc-1.0/blake3"
    },
    structurally_valid: %{shex_result: %{conformant: true, shape_map: "<s>@<Shape>"}},
    semantically_valid: %{shacl_report: %{conforms: true, results: []}},
    closed: %{closure: %{rule_count: 7, entailed_triple_count: 51}},
    falsifier_clean: %{falsifiers: ["urn:sa2a:falsifier:no-orphan-subject"], violations: []},
    admitted: %{admission_receipt_id: "urn:receipt:admission:1"},
    plannable: %{planning_fingerprint: "sha256:abc", goal_count: 1},
    selected: %{plan_id: "urn:plan:1", step_count: 3},
    constructed: %{command_id: "command:c1", capability_id: "MyApp.Facility.advance"},
    authorized: %{authority_id: "authority:a1", scope: "facility:advance"},
    prepared: %{receipt_anchor_id: "urn:receipt:anchor:1"},
    executed: %{execution_id: "execution:e1", consequence: :change},
    receipted: %{receipt_id: "urn:receipt:1", status: :ok},
    attested: %{receipt_id: "urn:receipt:1", attestation: "sha256:attest"}
  }

  defp candidate do
    {:ok, envelope} =
      Envelope.new(%{envelope_id: "urn:uuid:standing-test", kind: "sa2a:Request"})

    envelope
  end

  # Walks the real chain from :candidate up to (and including) `target`.
  #
  # Every test that needs an envelope *at* some standing goes through here
  # rather than poking `%{envelope | standing: x}`: since the anti-forgery
  # ledger landed, a struct-poked standing is refused
  # (`:standing_ledger_absent`), which is the point -- so the only way to be
  # at a standing in a test is the same way as in production, by earning it.
  defp at(:candidate), do: candidate()
  defp at(target), do: walk_to(target)

  # A real envelope at a terminal standing, reached by a real terminal
  # transition carrying a refusal of a class that terminal actually admits.
  defp at_terminal(terminal) do
    class =
      case terminal do
        :refused -> hd(Refusal.refused_classes())
        :blocked -> hd(Refusal.blocked_classes())
        :unknown -> :blocked_unknown
        :unsupported -> hd(Refusal.unsupported_classes())
        :failed -> :blocked_resource
      end

    {:ok, envelope} =
      Standing.transition(candidate(), terminal, %{
        refusal: Refusal.new(class, :terminal_fixture, :terminal_fixture)
      })

    envelope
  end

  defp walk_to(target) do
    Standing.states()
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 != target))
    |> Kernel.++([target])
    |> Enum.reduce(candidate(), fn step, envelope ->
      {:ok, next} = Standing.transition(envelope, step, Map.fetch!(@evidence, step))
      next
    end)
  end

  describe "the S41 chain" do
    test "is exactly the RFC order, with :candidate as genesis" do
      assert Standing.states() == [
               :candidate,
               :received,
               :parsed,
               :identified,
               :structurally_valid,
               :semantically_valid,
               :closed,
               :falsifier_clean,
               :admitted,
               :plannable,
               :selected,
               :constructed,
               :authorized,
               :prepared,
               :executed,
               :receipted,
               :attested
             ]
    end

    test "terminal states are the RFC five and are all absorbing" do
      assert Standing.terminal_states() == [:refused, :blocked, :unknown, :unsupported, :failed]

      for state <- Standing.terminal_states() do
        assert Standing.terminal?(state)
        assert Standing.rank(state) == nil
      end

      for state <- Standing.states() do
        refute Standing.terminal?(state)
        assert is_integer(Standing.rank(state))
      end
    end

    test "predecessor/1 is the REQUIRED predecessor of every chain state" do
      assert Standing.predecessor(:candidate) == nil
      assert Standing.predecessor(:received) == :candidate
      assert Standing.predecessor(:admitted) == :falsifier_clean
      assert Standing.predecessor(:attested) == :receipted

      Standing.states()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] ->
        assert Standing.predecessor(next) == previous
      end)
    end
  end

  describe "the full evidenced walk" do
    test "every step is reachable with real evidence, in order, ending at :attested" do
      final = walk_to(:attested)

      assert final.standing == :attested
      assert length(final.standing_history) == 16

      assert Enum.map(final.standing_history, & &1.to) == Enum.drop(Standing.states(), 1)
      assert Enum.map(final.standing_history, & &1.from) == Enum.drop(Standing.states(), -1)
    end

    test "each history entry carries the real evidence digest for that step" do
      final = walk_to(:attested)

      for entry <- final.standing_history do
        assert entry.evidence_digest == Envelope.evidence_digest(Map.fetch!(@evidence, entry.to))
      end
    end

    test "reaching :admitted takes eight evidenced transitions -- received is not admitted" do
      received = walk_to(:received)
      assert received.standing == :received
      refute received.standing == :admitted

      admitted = walk_to(:admitted)
      assert admitted.standing == :admitted
      assert length(admitted.standing_history) == 8
    end
  end

  describe "no transition may skip a REQUIRED predecessor" do
    test "candidate -> admitted is refused and names the required predecessor" do
      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :admitted, @evidence.admitted)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_predecessor_skipped
      assert refusal.stage == :admitted
      assert refusal.detail == %{from: :candidate, to: :admitted, required: :falsifier_clean}
      assert refusal.lawful? == true
    end

    test "EVERY non-adjacent forward jump in the whole chain is refused" do
      chain = Standing.states()

      for {from, from_index} <- Enum.with_index(chain),
          {to, to_index} <- Enum.with_index(chain),
          to_index != from_index + 1,
          to != :candidate do
        envelope = at(from)

        assert {:error, %Refusal{code: :standing_predecessor_skipped}} =
                 Standing.transition(envelope, to, Map.get(@evidence, to, %{})),
               "#{from} -> #{to} was not refused"
      end
    end

    test "a backward transition is refused (standing never falls silently)" do
      admitted = walk_to(:admitted)

      assert {:error, %Refusal{code: :standing_predecessor_skipped} = refusal} =
               Standing.transition(admitted, :parsed, @evidence.parsed)

      assert refusal.detail == %{from: :admitted, to: :parsed, required: :received}
    end

    test "a state that is not in the chain at all is REFUSED_STRUCTURE" do
      assert {:error, %Refusal{class: :refused_structure, code: :standing_state_unknown}} =
               Standing.transition(candidate(), :sovereign, %{})
    end
  end

  describe "S6: standing MUST NOT be inferred" do
    test "all 11 forbidden inference sources have a reserved evidence key" do
      assert length(Standing.forbidden_inference_keys()) == 11
      assert Enum.uniq(Standing.forbidden_inference_keys()) == Standing.forbidden_inference_keys()
    end

    test "every forbidden key is refused as evidence, atom-keyed or string-keyed" do
      for key <- Standing.forbidden_inference_keys() do
        atom_keyed = Map.put(@evidence.received, key, "whatever")
        string_keyed = Map.put(@evidence.received, Atom.to_string(key), "whatever")

        for evidence <- [atom_keyed, string_keyed] do
          assert {:error, %Refusal{} = refusal} =
                   Standing.transition(candidate(), :received, evidence),
                 "#{key} was accepted as evidence"

          assert refusal.class == :refused_meta_rigor
          assert refusal.code == :standing_inferred
          assert refusal.detail.forbidden_inference_sources == [key]
        end
      end
    end

    test "a forbidden key cannot be laundered by bundling it with otherwise-valid evidence" do
      # This is the whole point: the evidence below is genuinely sufficient
      # for :received. It is still refused, because :llm_output rode along.
      evidence = Map.put(@evidence.received, :llm_output, "the model says this is fine")

      assert {:error, %Refusal{code: :standing_inferred}} =
               Standing.transition(candidate(), :received, evidence)

      # Remove the forbidden key and the exact same evidence is admitted.
      assert {:ok, envelope} = Standing.transition(candidate(), :received, @evidence.received)
      assert envelope.standing == :received
    end

    test "several forbidden keys at once are all named in the refusal detail" do
      evidence =
        @evidence.received
        |> Map.put(:confidence, 0.99)
        |> Map.put(:no_error, true)
        |> Map.put(:hook_fired, "before_admit")

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert Enum.sort(refusal.detail.forbidden_inference_sources) ==
               [:confidence, :hook_fired, :no_error]
    end
  end

  describe "evidence appropriate to each step is REQUIRED" do
    test "no step is reachable with empty evidence" do
      for step <- Enum.drop(Standing.states(), 1) do
        envelope = at(Standing.predecessor(step))

        assert {:error, %Refusal{code: :standing_evidence_missing} = refusal} =
                 Standing.transition(envelope, step, %{}),
               "#{step} was reachable with no evidence at all"

        assert refusal.class == Standing.evidence_class(step)
        assert refusal.stage == step
      end
    end

    test "each step's missing keys are named specifically" do
      envelope = at(:falsifier_clean)

      assert {:error, %Refusal{} = refusal} = Standing.transition(envelope, :admitted, %{})
      assert refusal.class == :refused_receipt
      assert refusal.detail.missing == [:admission_receipt_id]
      assert refusal.detail.required == [:admission_receipt_id]
    end

    test ":structurally_valid requires a real ShEx result that actually conformed" do
      envelope = at(:identified)

      # No ShEx result at all.
      assert {:error, %Refusal{class: :refused_structure, code: :standing_evidence_missing}} =
               Standing.transition(envelope, :structurally_valid, %{})

      # A ShEx result that did NOT conform.
      assert {:error, %Refusal{class: :refused_structure, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :structurally_valid, %{
                 shex_result: %{conformant: false}
               })

      # A real conformant result admits.
      assert {:ok, next} =
               Standing.transition(envelope, :structurally_valid, @evidence.structurally_valid)

      assert next.standing == :structurally_valid
    end

    test ":semantically_valid requires a conformant SHACL report and refuses as REFUSED_SHACL" do
      envelope = at(:structurally_valid)

      assert {:error, %Refusal{class: :refused_shacl, code: :standing_evidence_missing}} =
               Standing.transition(envelope, :semantically_valid, %{})

      assert {:error, %Refusal{class: :refused_shacl, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :semantically_valid, %{
                 shacl_report: %{conforms: false, results: [%{path: "ex:p"}]}
               })

      assert {:ok, next} =
               Standing.transition(envelope, :semantically_valid, @evidence.semantically_valid)

      assert next.standing == :semantically_valid
    end

    test ":falsifier_clean refuses a claim with no declared falsifiers" do
      envelope = at(:closed)

      assert {:error, %Refusal{class: :refused_falsifier, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :falsifier_clean, %{falsifiers: [], violations: []})
    end

    test ":falsifier_clean refuses when a declared falsifier actually fired" do
      envelope = at(:closed)

      assert {:error, %Refusal{class: :refused_falsifier} = refusal} =
               Standing.transition(envelope, :falsifier_clean, %{
                 falsifiers: ["urn:sa2a:falsifier:f1"],
                 violations: [%{falsifier: "urn:sa2a:falsifier:f1", at: "ex:s"}]
               })

      assert refusal.detail.violations == [%{falsifier: "urn:sa2a:falsifier:f1", at: "ex:s"}]
    end

    test ":closed requires a real closure result with an entailed triple count" do
      envelope = at(:semantically_valid)

      assert {:error, %Refusal{class: :refused_rule, code: :standing_evidence_invalid}} =
               Standing.transition(envelope, :closed, %{closure: %{rule_count: 3}})

      assert {:error, %Refusal{class: :refused_rule}} =
               Standing.transition(envelope, :closed, %{closure: "done"})
    end

    test ":plannable and :selected require positive counts, not merely present ones" do
      plannable_from = at(:admitted)

      assert {:error, %Refusal{class: :refused_plan, code: :standing_evidence_invalid}} =
               Standing.transition(plannable_from, :plannable, %{
                 planning_fingerprint: "sha256:abc",
                 goal_count: 0
               })

      selected_from = at(:plannable)

      assert {:error, %Refusal{class: :refused_plan, code: :standing_evidence_invalid}} =
               Standing.transition(selected_from, :selected, %{plan_id: "p", step_count: 0})
    end

    test ":parsed requires a non-negative integer triple count" do
      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(walk_to(:received), :parsed, %{
                 media_type: "text/turtle",
                 triple_count: "lots"
               })
    end

    test "string-keyed evidence is accepted (it is the real wire shape)" do
      assert {:ok, envelope} =
               Standing.transition(candidate(), :received, %{
                 "transport" => "a2a/https",
                 "received_at" => "2026-09-16T00:00:00Z"
               })

      assert envelope.standing == :received
    end

    test "each step's evidence-failure class matches the class that owns that step" do
      expected = %{
        received: :refused_structure,
        parsed: :refused_structure,
        identified: :refused_identity,
        structurally_valid: :refused_structure,
        semantically_valid: :refused_shacl,
        closed: :refused_rule,
        falsifier_clean: :refused_falsifier,
        admitted: :refused_receipt,
        plannable: :refused_plan,
        selected: :refused_plan,
        constructed: :refused_capability,
        authorized: :refused_authority,
        prepared: :refused_receipt,
        executed: :refused_consequence,
        receipted: :refused_receipt,
        attested: :refused_provenance
      }

      for {step, class} <- expected do
        assert Standing.evidence_class(step) == class
        assert Refusal.class?(class)
      end
    end
  end

  describe "envelope bounds are honoured at :parsed (REFUSED_BOUNDS)" do
    test "a triple count over the declared maxTriples bound is refused" do
      {:ok, bounded} =
        Envelope.new(%{
          envelope_id: "urn:uuid:bounded",
          kind: "sa2a:Request",
          bounds: %{"maxTriples" => 10}
        })

      {:ok, received} = Standing.transition(bounded, :received, @evidence.received)

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(received, :parsed, %{
                 media_type: "text/turtle",
                 triple_count: 11
               })

      assert refusal.class == :refused_bounds
      assert refusal.code == :standing_bounds_exceeded
      assert refusal.detail == %{bound: :maxTriples, limit: 10, observed: 11}
    end

    test "a triple count at the bound is admitted" do
      {:ok, bounded} =
        Envelope.new(%{
          envelope_id: "urn:uuid:bounded-ok",
          kind: "sa2a:Request",
          bounds: %{"maxTriples" => 10}
        })

      {:ok, received} = Standing.transition(bounded, :received, @evidence.received)

      assert {:ok, parsed} =
               Standing.transition(received, :parsed, %{
                 media_type: "text/turtle",
                 triple_count: 10
               })

      assert parsed.standing == :parsed
    end
  end

  describe "terminal transitions (a refusal is a lawful outcome)" do
    test "any non-terminal state may transition to :refused with a real refusal" do
      refusal = Refusal.new(:refused_shacl, :shacl_nonconformant, :semantically_valid, %{n: 2})

      for state <- Standing.states() do
        envelope = at(state)

        assert {:ok, refused} = Standing.transition(envelope, :refused, %{refusal: refusal})
        assert refused.standing == :refused
        assert %{from: ^state, to: :refused} = List.last(refused.standing_history)
      end
    end

    test "the terminal history entry records the refusal class/code/stage" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)

      {:ok, refused} = Standing.transition(walk_to(:constructed), :refused, %{refusal: refusal})

      entry = List.last(refused.standing_history)
      assert entry.to == :refused
      assert entry.evidence_keys == ["refusal_class", "refusal_code", "refusal_stage"]
    end

    test "terminal class families are enforced: a REFUSED_* class cannot land in :blocked" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid} = error} =
               Standing.transition(candidate(), :blocked, %{refusal: refusal})

      assert error.detail.refusal_class == :refused_authority
      assert error.detail.admissible_classes == Refusal.blocked_classes()
    end

    test "BLOCKED_RESOURCE lands in :blocked, BLOCKED_UNKNOWN in :unknown" do
      assert {:ok, blocked} =
               Standing.transition(candidate(), :blocked, %{
                 refusal: Refusal.new(:blocked_resource, :hddl_cli_not_built, :plan)
               })

      assert blocked.standing == :blocked

      assert {:ok, unknown} =
               Standing.transition(candidate(), :unknown, %{
                 refusal: Refusal.new(:blocked_unknown, :unclassified_error, :parse)
               })

      assert unknown.standing == :unknown
    end

    test "UNSUPPORTED_PROFILE lands in :unsupported and nothing else does" do
      assert {:ok, unsupported} =
               Standing.transition(candidate(), :unsupported, %{
                 refusal: Refusal.new(:unsupported_profile, :unknown_profile, :envelope)
               })

      assert unsupported.standing == :unsupported

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid}} =
               Standing.transition(candidate(), :unsupported, %{
                 refusal: Refusal.new(:blocked_resource, :enoent, :parse)
               })
    end

    test ":failed accepts any refusal class" do
      for class <- Refusal.classes() do
        assert {:ok, failed} =
                 Standing.transition(candidate(), :failed, %{
                   refusal: Refusal.new(class, :some_code, :some_stage)
                 })

        assert failed.standing == :failed
      end
    end

    test "a terminal transition without a real Refusal struct is refused" do
      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :refused, %{reason: "because"})

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_terminal_evidence_invalid
      assert refusal.detail.evidence_keys == ["reason"]

      assert {:error, %Refusal{code: :standing_terminal_evidence_invalid}} =
               Standing.transition(candidate(), :refused, %{})
    end
  end

  describe "terminal states are absorbing" do
    test "nothing transitions out of a terminal state, forward or terminal" do
      for terminal <- Standing.terminal_states() do
        envelope = at_terminal(terminal)

        assert {:error, %Refusal{code: :standing_terminal} = refusal} =
                 Standing.transition(envelope, :received, @evidence.received)

        assert refusal.class == :refused_meta_rigor
        assert refusal.detail.from == terminal

        assert {:error, %Refusal{code: :standing_terminal}} =
                 Standing.transition(envelope, :failed, %{
                   refusal: Refusal.new(:blocked_unknown, :c, :s)
                 })
      end
    end
  end

  describe "DEFECT 3 regression: standing carried on the struct cannot be forged" do
    test "the verifier's minimal 3-line repro -- a struct built directly with standing: :admitted" do
      # Measured before the fix: this returned {:ok, envelope} at :plannable,
      # because transition/3 read :standing straight off the struct.
      forged = %Envelope{
        envelope_id: "urn:uuid:forged",
        kind: "sa2a:Request",
        standing: :admitted
      }

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(forged, :plannable, @evidence.plannable)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_ledger_absent
      assert refusal.detail.claimed_standing == :admitted
    end

    test "EVERY non-genesis standing is unreachable by struct forgery" do
      for state <- Standing.states() ++ Standing.terminal_states(), state != :candidate do
        forged = %Envelope{envelope_id: "urn:uuid:f", kind: "sa2a:Request", standing: state}

        assert {:error, %Refusal{code: :standing_ledger_absent}} =
                 Standing.transition(forged, :received, @evidence.received),
               "forging standing #{state} was not refused"
      end
    end

    test "a hand-fabricated standing history is refused: the seal does not verify" do
      fabricated = [
        %{
          from: :candidate,
          to: :admitted,
          at: "2026-01-01T00:00:00Z",
          evidence_keys: ["admission_receipt_id"],
          evidence_digest: "sha256:deadbeef"
        }
      ]

      forged = %Envelope{
        envelope_id: "urn:uuid:f",
        kind: "sa2a:Request",
        standing: :admitted,
        standing_history: fabricated,
        standing_seal:
          "hmac-sha256:0000000000000000000000000000000000000000000000000000000000000000"
      }

      assert {:error, %Refusal{code: :standing_ledger_unsealed}} =
               Standing.transition(forged, :plannable, @evidence.plannable)
    end

    test "a genuinely-earned ledger whose entries are then tampered with is refused" do
      admitted = at(:admitted)
      [first | rest] = admitted.standing_history

      tampered = %{admitted | standing_history: [%{first | to: :admitted} | rest]}

      assert {:error, %Refusal{code: :standing_ledger_discontinuous}} =
               Standing.transition(tampered, :plannable, @evidence.plannable)
    end

    test "a real ledger whose standing runs ahead of its own evidence is refused" do
      parsed = at(:parsed)
      ahead = %{parsed | standing: :admitted}

      assert {:error, %Refusal{code: :standing_ledger_inconsistent} = refusal} =
               Standing.transition(ahead, :plannable, @evidence.plannable)

      assert refusal.detail.claimed_standing == :admitted
      assert refusal.detail.evidenced_standing == :parsed
    end

    test "the lawful 8-step walk to :admitted still works and produces a verifying seal" do
      admitted = at(:admitted)

      assert admitted.standing == :admitted
      assert length(admitted.standing_history) == 8
      assert String.starts_with?(admitted.standing_seal, "hmac-sha256:")

      # And it keeps going lawfully from there.
      assert {:ok, plannable} = Standing.transition(admitted, :plannable, @evidence.plannable)
      assert plannable.standing == :plannable
      assert length(plannable.standing_history) == 9
    end

    test "skip-prevention is preserved on top of the ledger, not replaced by it" do
      # The ledger check runs FIRST, so this envelope is genuinely at :parsed
      # -- the refusal below is the original predecessor rule still firing.
      parsed = at(:parsed)

      assert {:error, %Refusal{code: :standing_predecessor_skipped} = refusal} =
               Standing.transition(parsed, :admitted, @evidence.admitted)

      assert refusal.detail == %{from: :parsed, to: :admitted, required: :falsifier_clean}
    end
  end

  describe "DEFECT 4 regression: an inference cannot be laundered by nesting it" do
    test "the verifier's minimal repro -- a forbidden key one level down" do
      # Measured before the fix: {:ok, envelope} at :received, because
      # reject_inference/2 only scanned top-level keys with Map.has_key?/2.
      evidence =
        Map.merge(@evidence.received, %{bundle: %{llm_output: "the model says it is fine"}})

      assert {:error, %Refusal{} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.class == :refused_meta_rigor
      assert refusal.code == :standing_inferred
      assert refusal.detail.forbidden_inference_sources == [:llm_output]
      assert refusal.detail.forbidden_inference_paths == [["bundle", "llm_output"]]
    end

    test "every forbidden key is caught at depth, atom-keyed and string-keyed alike" do
      for key <- Standing.forbidden_inference_keys(),
          nested <- [%{key => true}, %{Atom.to_string(key) => true}] do
        evidence = Map.merge(@evidence.received, %{wrapper: %{inner: nested}})

        assert {:error, %Refusal{code: :standing_inferred} = refusal} =
                 Standing.transition(candidate(), :received, evidence),
               "nested #{key} was not refused"

        assert refusal.detail.forbidden_inference_sources == [key]
        assert refusal.detail.forbidden_inference_paths == [["wrapper", "inner", key_name(key)]]
      end
    end

    test "a forbidden key buried inside a list is caught, with its index in the path" do
      evidence =
        Map.merge(@evidence.received, %{
          results: [%{ok: true}, %{meta: %{"confidence" => 0.99}}]
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_sources == [:confidence]
      assert refusal.detail.forbidden_inference_paths == [["results", 1, "meta", "confidence"]]
    end

    test "a struct value does not raise Protocol.UndefinedError, it is scanned" do
      # is_map/1 is true for a struct but a struct is not Enumerable, so the
      # naive recursive walk raises here. A plain struct carrying no forbidden
      # field must simply pass.
      evidence = Map.merge(@evidence.received, %{observed_at: ~U[2026-09-16 00:00:00Z]})

      assert {:ok, received} = Standing.transition(candidate(), :received, evidence)
      assert received.standing == :received
    end

    test "a struct CARRYING a forbidden field is refused, not skipped" do
      evidence =
        Map.merge(@evidence.received, %{
          probe: %AshA2A.SemanticStandingTest.LaunderingStruct{label: "x", hook_fired: true}
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_sources == [:hook_fired]
      assert refusal.detail.forbidden_inference_paths == [["probe", "hook_fired"]]
    end

    test "a struct nested inside a list inside a map is still scanned" do
      evidence =
        Map.merge(@evidence.received, %{
          audit: [
            %{step: 1},
            %{
              trace: %AshA2A.SemanticStandingTest.LaunderingStruct{
                label: "y",
                hook_fired: false
              }
            }
          ]
        })

      assert {:error, %Refusal{code: :standing_inferred} = refusal} =
               Standing.transition(candidate(), :received, evidence)

      assert refusal.detail.forbidden_inference_paths == [["audit", 1, "trace", "hook_fired"]]
    end

    test "evidence nested past the scan depth is refused, never scanned partially" do
      deep =
        Enum.reduce(1..(Standing.max_evidence_depth() + 5), %{leaf: true}, fn _i, acc ->
          %{nested: acc}
        end)

      assert {:error, %Refusal{code: :standing_evidence_too_deep} = refusal} =
               Standing.transition(candidate(), :received, Map.merge(@evidence.received, deep))

      assert refusal.class == :refused_meta_rigor
      assert refusal.detail.max_depth == Standing.max_evidence_depth()
    end

    test "clean nested evidence still passes -- the scan bans keys, not nesting" do
      evidence =
        Map.merge(@evidence.received, %{
          transport_detail: %{tls: %{version: "1.3", cipher: "TLS_AES_256_GCM_SHA384"}},
          hops: [%{host: "a"}, %{host: "b"}]
        })

      assert {:ok, received} = Standing.transition(candidate(), :received, evidence)
      assert received.standing == :received
    end
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)

  describe "transition/3 never raises on malformed input" do
    test "non-map evidence is a refusal, not an exception" do
      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(candidate(), :received, "not a map")

      assert {:error, %Refusal{code: :standing_evidence_invalid}} =
               Standing.transition(candidate(), :received, nil)
    end
  end
end

# --- SECTION 8: Original test/ash_a2a/semantic_synthesis_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Planning.SemanticSynthesisTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Planning.SemanticSynthesis
  alias AshA2A.Test.Fixture.Echo

  setup do
    previous = Application.get_env(:ash_a2a, :llm_profiles, [])

    Application.put_env(:ash_a2a, :llm_profiles,
      surface_planner: [provider: :zai_coder, model: "glm-5.3-flash", max_tokens: 4096]
    )

    on_exit(fn -> Application.put_env(:ash_a2a, :llm_profiles, previous) end)
  end

  test "ZAI role can synthesize a candidate but cannot gain DO authority" do
    generator = fn model_spec, prompt, schema, opts ->
      assert model_spec == "zai_coder:glm-5.3-flash"
      assert opts[:max_tokens] == 4096
      assert prompt =~ "Canonical capability ids"
      assert get_in(schema, ["properties", "authority", "enum"]) == ["none"]

      {:ok,
       %{
         "request_id" => "surface-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task inspect-surface)",
         "fond" => "(:policy observe-or-replan)",
         "rationale" => "observe before selecting"
       }}
    end

    assert {:ok, candidate} =
             SemanticSynthesis.synthesize(
               Echo,
               "verify the accessible surface",
               %{"aria" => [%{"role" => "button", "name" => "Continue"}]},
               generate_object: generator
             )

    assert candidate.planner == :semantic_synthesis
    assert candidate.formalism == :hddl_fond
    assert candidate.standing == :candidate
    assert candidate.authority == :none
    assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]
    assert candidate.plan["authority"] == "none"
    assert candidate.plan["synthesis"]["role"] == "surface_planner"
  end

  test "semantic model authority claims are refused before capability admission" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-do",
         "authority" => "do",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :planner_authority_ceiling_violated}} =
             SemanticSynthesis.synthesize(Echo, "actuate", %{}, generate_object: generator)
  end

  test "noncanonical model-selected capability is refused by canonical A2A admission" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-invalid-capability",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.delete_everything"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :noncanonical_capability}} =
             SemanticSynthesis.synthesize(Echo, "invent a capability", %{},
               generate_object: generator
             )
  end

  defmodule NoCapabilities.Resource do
    @moduledoc """
    Real fixture resource, local to this test file, with `extensions:
    [AshA2A]` attached but zero public actions (`defaults([])`) and no `a2a
    do skill ... end` block -- so `AshA2A.CapabilityIndex.Compiler.compile/3`
    has zero `Ash.Resource.Info.public_actions/1` to project and zero
    overrides, yielding a provably empty capability index for the
    `:no_canonical_capabilities` short-circuit test below.
    """

    use Ash.Resource,
      domain: AshA2A.Planning.SemanticSynthesisTest.NoCapabilities.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([])
    end
  end

  defmodule NoCapabilities.Domain do
    @moduledoc """
    Real fixture domain pairing `NoCapabilities.Resource` above, mirroring
    `AshA2A.Test.Fixture.Domain`'s shape.
    """

    use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

    resources do
      resource(AshA2A.Planning.SemanticSynthesisTest.NoCapabilities.Resource)
    end
  end

  test ":no_canonical_capabilities short-circuits before any generate_object call" do
    assert SemanticSynthesis.capability_ids(NoCapabilities.Domain) == []

    generator = fn _model_spec, _prompt, _schema, _opts ->
      raise "must not be called"
    end

    assert {:error, %{code: :no_canonical_capabilities}} =
             SemanticSynthesis.synthesize(NoCapabilities.Domain, "some goal", %{},
               generate_object: generator
             )
  end

  test "invalid_semantic_plan_shape: empty capability_ids list" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-empty",
         "authority" => "none",
         "capability_ids" => [],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: non-string capability id" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-nonstring",
         "authority" => "none",
         "capability_ids" => [123],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: missing request_id" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: proposal is not a map" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok, "not a map at all"}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "semantic_synthesis_failed wraps a raw non-code error reason" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:error, "raw reason string"}
    end

    assert {:error, %{code: :semantic_synthesis_failed, detail: "raw reason string"}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "capability_ids/1 returns the sorted, stringified canonical Echo capability ids" do
    assert SemanticSynthesis.capability_ids(Echo) == ["AshA2A.Test.Fixture.Echo.read"]
  end

  test "authority ceiling admits ONLY the literal string \"none\", closed over every other representation" do
    # Fuzz/regression coverage for `normalize_proposal/2`'s real authority
    # check (`if authority == "none" do ... else {:error,
    # refusal(:planner_authority_ceiling_violated, authority)} end`, reading
    # the value via `field/2` = `Map.get(map, "authority") || Map.get(map,
    # :authority)`). Every case below keeps `capability_ids`, `hddl`, and
    # `fond` well-formed and schema-valid so the only variable under test is
    # the literal value returned for "authority" -- proving the ceiling is a
    # closed, exact-string comparison and not a loose truthiness/type check.
    base = %{
      "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
      "hddl" => "(:task inspect-surface)",
      "fond" => "(:policy observe-or-replan)"
    }

    cases = [
      {"exact literal string", "none", :ok},
      {"uppercase", "NONE", {:error, :planner_authority_ceiling_violated, "NONE"}},
      {"atom :none", :none, {:error, :planner_authority_ceiling_violated, :none}},
      {"trailing space", "none ", {:error, :planner_authority_ceiling_violated, "none "}},
      {"capitalized", "None", {:error, :planner_authority_ceiling_violated, "None"}},
      {"nil", nil, {:error, :planner_authority_ceiling_violated, nil}},
      {"boolean true", true, {:error, :planner_authority_ceiling_violated, true}},
      {"admin string", "admin", {:error, :planner_authority_ceiling_violated, "admin"}},
      {"do string", "do", {:error, :planner_authority_ceiling_violated, "do"}},
      {"integer zero", 0, {:error, :planner_authority_ceiling_violated, 0}},
      {"empty list", [], {:error, :planner_authority_ceiling_violated, []}}
    ]

    for {label, authority_value, expected} <- cases do
      request_id = "authority-fuzz-" <> String.replace(label, " ", "-")

      generator = fn _model_spec, _prompt, _schema, _opts ->
        {:ok, Map.merge(base, %{"request_id" => request_id, "authority" => authority_value})}
      end

      result =
        SemanticSynthesis.synthesize(Echo, "probe authority ceiling", %{},
          generate_object: generator
        )

      case expected do
        :ok ->
          assert {:ok, candidate} = result
          assert candidate.plan["authority"] == "none"
          assert candidate.authority == :none
          assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]

        {:error, code, detail} ->
          assert {:error, %{code: ^code, detail: ^detail}} = result
      end
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/semantic_vocabulary_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.VocabularyTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Vocabulary

  describe "prefixes/0" do
    test "returns exactly the known prefix keys" do
      prefixes = Vocabulary.prefixes()

      # Pin updated for the canonical-ontology integration (commit b9467b3), which added
      # the a2a protocol namespace and the sa2a-fnd/cap/bp/evi FIBO-derived domains.
      assert MapSet.new(Map.keys(prefixes)) ==
               MapSet.new(
                 ~w(rdf rdfs owl prov time odrl skos schema oa sosa ssn saref qudt a2a sa2a-fnd sa2a-cap sa2a-bp sa2a-evi)
               )
    end

    test "known prefixes resolve to their expected URIs" do
      prefixes = Vocabulary.prefixes()

      assert prefixes["rdf"] == "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
      assert prefixes["schema"] == "https://schema.org/"
    end
  end

  describe "expand/1" do
    test "expands a known prefix:local pair by concatenation" do
      assert Vocabulary.expand("rdf:type") ==
               "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    end

    test "falls back to local/1 with the full original value when the prefix is unknown" do
      assert Vocabulary.expand("unknownprefix:foo") ==
               "urn:ash-a2a:semantic:unknownprefix_foo"
    end

    test "falls back to local/1 unchanged when there is no colon at all" do
      assert Vocabulary.expand("noColonAtAll") == "urn:ash-a2a:semantic:noColonAtAll"
    end
  end

  describe "local/1" do
    test "collapses each run of non alnum/./_/- characters into a single underscore" do
      assert Vocabulary.local("has space:and/slash") ==
               "urn:ash-a2a:semantic:has_space_and_slash"
    end

    test "leaves already-safe characters untouched" do
      assert Vocabulary.local("already-safe.value_123") ==
               "urn:ash-a2a:semantic:already-safe.value_123"
    end
  end
end

# --- SECTION 10: Original test/ash_a2a/skill_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SkillTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of the `AshA2A.Skill` struct itself. Existing tests only
  ever inspect `AshA2A.Skill` entries as they come out of a compiled DSL
  extension (via `AshA2A.Info`/capability index tests); none constructs the
  struct directly and asserts on its own real default values.
  """

  test "struct defaults to nil for all fields, with __spark_metadata__ nil" do
    skill = %AshA2A.Skill{}

    assert skill.name == nil
    assert skill.resource == nil
    assert skill.domain == nil
    assert skill.action == nil
    assert skill.arguments == []
    assert skill.__spark_metadata__ == nil
  end

  test "struct holds real, independently-set field values" do
    skill = %AshA2A.Skill{
      name: :echo,
      resource: AshA2A.Test.Fixture.Echo,
      domain: AshA2A.Test.Fixture.Domain,
      action: :read
    }

    assert skill.name == :echo
    assert skill.resource == AshA2A.Test.Fixture.Echo
    assert skill.domain == AshA2A.Test.Fixture.Domain
    assert skill.action == :read
  end
end

# --- SECTION 11: Original test/ash_a2a/soak_cross_product_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SoakCrossProductTest do
  @moduledoc """
  Verifies the dynamic capability cross product space between `ash_a2a` and `ash_pplan`.
  Asserts that:
    1. Capabilities in `ash_a2a` and `ash_pplan` are discovered dynamically.
    2. The Cartesian space contains all expected capability interaction pairs.
    3. Soak evaluation runs cleanly with bounded memory and zero errors.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  test "dynamic cross product of ash_a2a and ash_pplan capabilities" do
    a2a_skills = Mix.Tasks.AshA2a.SoakTest.discover_a2a_skills()
    pplan_caps = Mix.Tasks.AshA2a.SoakTest.discover_pplan_capabilities()

    assert length(a2a_skills) > 0
    assert length(pplan_caps) > 0

    cross_product =
      for a <- a2a_skills, p <- pplan_caps do
        {a.id, p.id}
      end

    expected_size = length(a2a_skills) * length(pplan_caps)
    assert length(cross_product) == expected_size
    assert expected_size >= 100

    # Ensure all pplan capabilities parse under AshPPlan.Capability
    for {_a_id, p_id} <- cross_product do
      assert {:ok, _cap} = AshPPlan.Capability.parse(p_id)
    end
  end

  test "soak test runs sample cross-product evaluation batch cleanly" do
    # Run 10,000 evaluations across schedulers
    assert :ok = Mix.Tasks.AshA2a.SoakTest.run(["--agents", "10000", "--batch-size", "2500"])
  end
end

# --- SECTION 12: Original test/ash_a2a/task_lifecycle_state_machine_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskLifecycleStateMachineTest do
  @moduledoc """
  GAP D (Squad D, agents 16-17) -- closes `AshStateMachine:
  UNSUPPORTED -> ALIVE` with real evidence.

  `:ash_state_machine` is now a real, resolvable dependency (`mix.exs`:
  `{:ash_state_machine, "~> 0.2"}`), so `AshA2A.TaskLifecycle.available?()`
  is real `true` and `lib/ash_a2a/task_lifecycle.ex`'s
  `{:error, {:unsupported, :ash_state_machine}}` degrade branch
  (`possible_next_states/2`'s `not available?()` clause) is now provably
  unreachable for a resource that genuinely carries the extension -- this
  test proves that by never hitting it.

  Three real things are proven against
  `AshA2A.Test.Fixture.StateMachineTask` (`test/support/state_machine_fixture.ex`,
  a genuine `Ash.Resource` with `extensions: [AshStateMachine]`, not a
  hand-rolled imitation):

    1. A real Ash create + real Ash update action genuinely transitions the
       real persisted `:state` attribute through the real `AshStateMachine`
       extension (`transition_state/1` builtin change), verified by
       re-reading the record from the real `Ash.DataLayer.Ets` table after
       each transition -- not just inspecting the in-memory changeset
       result.
    2. `AshA2A.TaskLifecycle.possible_next_states/2` called against the
       real fixture resource+state returns real values sourced from the
       real `AshStateMachine.possible_next_states/1,2` functions -- the
       `{:error, {:unsupported, ...}}` degrade path is asserted absent.
    3. An invalid/disallowed transition is really refused by the real
       extension: calling the `:complete` action on a record still in
       `:submitted` (skipping `:start`) produces a real
       `Ash.Error.Invalid` wrapping a real
       `AshStateMachine.Errors.NoMatchingTransition` -- not a fabricated
       error term -- and `AshA2A.TaskLifecycle.admit/3` reports the same
       real refusal via its own `{:error, {:transition_not_admitted, _}}`
       shape.

  Chicago-style throughout: a real compiled `Ash.Resource` on a real
  `Ash.DataLayer.Ets` table, real `Ash.create!/2` and
  `Ash.Changeset.for_update/3` + `Ash.update/1` calls, state-based
  assertions on the real persisted attribute and the real returned
  error/ok tuples. Zero Mock/mox/patch/monkeypatch.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.Fixture.StateMachineTask
  alias AshA2A.TaskLifecycle

  describe "real dependency availability (GAP D closure precondition)" do
    test "AshStateMachine is really loaded and AshA2A.TaskLifecycle.available?/0 is really true" do
      assert Code.ensure_loaded?(AshStateMachine)
      assert TaskLifecycle.available?() == true
    end
  end

  describe "a real Ash action genuinely transitions real persisted state via AshStateMachine" do
    test "create sets the real persisted :state to the real default_initial_state" do
      task = Ash.create!(StateMachineTask, %{})

      assert task.state == :submitted

      # Re-read from the real ETS table -- not just the in-memory create
      # result -- to confirm the state was genuinely persisted.
      reloaded = Ash.get!(StateMachineTask, task.id)
      assert reloaded.state == :submitted
    end

    test "a real :start update transitions the real persisted state from :submitted to :working" do
      task = Ash.create!(StateMachineTask, %{})
      assert task.state == :submitted

      {:ok, started} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert started.state == :working

      reloaded = Ash.get!(StateMachineTask, task.id)
      assert reloaded.state == :working
    end

    test "a real full submitted -> working -> completed walk persists at every real hop" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert working.state == :working
      assert Ash.get!(StateMachineTask, task.id).state == :working

      {:ok, completed} =
        working
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      assert completed.state == :completed
      assert Ash.get!(StateMachineTask, task.id).state == :completed
    end

    test "a real submitted -> working -> failed walk persists the real terminal failure state" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, failed} =
        working
        |> Ash.Changeset.for_update(:fail, %{})
        |> Ash.update()

      assert failed.state == :failed
      assert Ash.get!(StateMachineTask, task.id).state == :failed
    end

    test "a real :cancel update is legal from :submitted (pre-execution cancellation)" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, canceled} =
        task
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update()

      assert canceled.state == :canceled
      assert Ash.get!(StateMachineTask, task.id).state == :canceled
    end
  end

  describe "AshA2A.TaskLifecycle.possible_next_states/2 sources real values from the real extension" do
    test "for a fresh :submitted record with no action filter, returns the real reachable states" do
      task = Ash.create!(StateMachineTask, %{})

      assert {:ok, next_states} = TaskLifecycle.possible_next_states(task)

      # Real transitions declared `from: :submitted`: :start (-> :working)
      # and :cancel (-> :canceled). Sorted so this assertion does not
      # depend on the real extension's internal enumeration order.
      assert Enum.sort(next_states) == [:canceled, :working]
    end

    test "for a fresh :submitted record filtered to the :start action, returns only :working" do
      task = Ash.create!(StateMachineTask, %{})

      assert {:ok, [:working]} = TaskLifecycle.possible_next_states(task, :start)
    end

    test "for a fresh :submitted record filtered to the :complete action, returns no real next states" do
      task = Ash.create!(StateMachineTask, %{})

      # The real :complete transition is declared `from: :working` only --
      # a :submitted record has no real matching transition for it.
      assert {:ok, []} = TaskLifecycle.possible_next_states(task, :complete)
    end

    test "for a :working record, returns the real reachable states from :working" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      assert {:ok, next_states} = TaskLifecycle.possible_next_states(working)
      assert Enum.sort(next_states) == [:canceled, :completed, :failed]
    end

    test "the {:error, {:unsupported, :ash_state_machine}} degrade path is provably unreachable here" do
      task = Ash.create!(StateMachineTask, %{})

      refute match?({:error, {:unsupported, _}}, TaskLifecycle.possible_next_states(task))
      refute match?({:error, {:unsupported, _}}, TaskLifecycle.possible_next_states(task, :start))
    end
  end

  describe "a real disallowed transition is really refused by AshStateMachine, not fabricated" do
    test "calling :complete on a :submitted record (skipping :start) raises a real Ash.Error.Invalid wrapping a real AshStateMachine.Errors.NoMatchingTransition" do
      task = Ash.create!(StateMachineTask, %{})
      assert task.state == :submitted

      result =
        task
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result

      assert Enum.any?(errors, fn
               %AshStateMachine.Errors.NoMatchingTransition{
                 old_state: :submitted,
                 target: :completed,
                 action: :complete
               } ->
                 true

               _ ->
                 false
             end)

      # The real refusal must not have mutated the real persisted state.
      assert Ash.get!(StateMachineTask, task.id).state == :submitted
    end

    test "calling :cancel on an already-:completed record is really refused (no transition leaves a terminal state)" do
      task = Ash.create!(StateMachineTask, %{})

      {:ok, working} =
        task
        |> Ash.Changeset.for_update(:start, %{})
        |> Ash.update()

      {:ok, completed} =
        working
        |> Ash.Changeset.for_update(:complete, %{})
        |> Ash.update()

      result =
        completed
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result

      assert Enum.any?(
               errors,
               &match?(%AshStateMachine.Errors.NoMatchingTransition{old_state: :completed}, &1)
             )
    end

    test "AshA2A.TaskLifecycle.admit/3 refuses the same real disallowed transition via its own real shape" do
      task = Ash.create!(StateMachineTask, %{})

      assert TaskLifecycle.admit(task, :completed, :complete) ==
               {:error, {:transition_not_admitted, :completed}}
    end

    test "AshA2A.TaskLifecycle.admit/3 admits a real legal transition" do
      task = Ash.create!(StateMachineTask, %{})

      assert TaskLifecycle.admit(task, :working, :start) == :ok
    end
  end
end

# --- SECTION 13: Original test/ash_a2a/task_store_ekv_test.exs ---
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TaskStoreEkvTest do
  @moduledoc """
  R3 (task durability, lane scope): `AshA2A.TaskStore.Ekv` against a real
  on-disk `EKV` instance and a real `AshA2A.Agent` GenServer
  (`AshA2A.Test.Fixture.EchoAgent`). Proves task state survives a real
  agent kill (`Process.exit(pid, :kill)`) and a real EKV restart against
  the same `data_dir`. No mocks.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Test.Fixture.EchoAgent
  alias AshA2A.TaskStore.Ekv, as: Store

  setup do
    id = System.unique_integer([:positive])
    name = :"ash_a2a_task_store_ekv_test_#{id}"
    data_dir = Path.join(System.tmp_dir!(), "ash_a2a_task_store_ekv_test_#{id}")
    File.rm_rf!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)

    start_supervised!(Store.child_spec(name: name, data_dir: data_dir))
    %{name: name, data_dir: data_dir}
  end

  defp task(id, context_id, state \\ :submitted) do
    %AshA2A.Protocol.Task{
      id: id,
      context_id: context_id,
      status: AshA2A.Protocol.Task.Status.new(state),
      history: [],
      artifacts: []
    }
  end

  test "put/get/list/list_all/delete round-trip", %{name: name} do
    assert {:error, :not_found} = Store.get(name, "t-1")

    assert :ok = Store.put(name, task("t-1", "ctx-a"))
    assert :ok = Store.put(name, task("t-2", "ctx-a", :completed))
    assert :ok = Store.put(name, task("t-3", "ctx-b"))

    assert {:ok, %AshA2A.Protocol.Task{id: "t-1", context_id: "ctx-a"}} = Store.get(name, "t-1")
    assert {:ok, ctx_a} = Store.list(name, "ctx-a")
    assert ctx_a |> Enum.map(& &1.id) |> Enum.sort() == ["t-1", "t-2"]

    assert {:ok, %{tasks: all}} = Store.list_all(name, [])
    assert all |> Enum.map(& &1.id) |> Enum.sort() == ["t-1", "t-2", "t-3"]

    assert :ok = Store.delete(name, "t-1")
    assert {:error, :not_found} = Store.get(name, "t-1")
  end

  test "tasks survive a real agent kill when the agent uses this store", %{name: name} do
    agent_name = :"echo_agent_durable_#{System.unique_integer([:positive])}"
    store = Store.task_store(name)

    {:ok, pid} = EchoAgent.start_link(name: agent_name, task_store: store)
    Process.unlink(pid)

    assert {:ok, %AshA2A.Protocol.Task{id: task_id} = created} =
             EchoAgent.call(agent_name, AshA2A.Protocol.Message.new_user("hello"))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    {:ok, restarted} = EchoAgent.start_link(name: agent_name, task_store: store)

    assert {:ok, %AshA2A.Protocol.Task{id: ^task_id} = recovered} =
             EchoAgent.get_task(agent_name, task_id)

    assert recovered.status.state == created.status.state
    GenServer.stop(restarted)

    # Control: an agent WITHOUT the store has lost the task after the same kill.
    control_name = :"echo_agent_memory_#{System.unique_integer([:positive])}"
    {:ok, control} = EchoAgent.start_link(name: control_name)
    Process.unlink(control)

    assert {:ok, %AshA2A.Protocol.Task{id: control_task_id}} =
             EchoAgent.call(control_name, AshA2A.Protocol.Message.new_user("hello"))

    control_ref = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}

    {:ok, control2} = EchoAgent.start_link(name: control_name)
    assert {:error, :not_found} = EchoAgent.get_task(control_name, control_task_id)
    GenServer.stop(control2)
  end

  test "tasks survive a real EKV restart against the same data_dir",
       %{name: name, data_dir: data_dir} do
    assert :ok = Store.put(name, task("persist-1", "ctx-p", :working))

    child_id = {EKV, name}
    assert :ok = stop_supervised(child_id)
    start_supervised!(Store.child_spec(name: name, data_dir: data_dir))

    assert {:ok, %AshA2A.Protocol.Task{id: "persist-1", context_id: "ctx-p"} = t} =
             Store.get(name, "persist-1")

    assert t.status.state == :working
  end

  test "a write EKV does not acknowledge raises instead of returning a silent error",
       %{name: name} do
    # A CAS-managed key refuses eventual (non-CAS) puts with
    # {:error, :cas_managed_key} -- a real, non-:ok EKV write result.
    assert {:ok, _vsn} = EKV.put(name, "a2a_task/cas-1", :placeholder, if_vsn: nil)

    assert_raise Store.WriteError, ~r/put of task "cas-1" failed/, fn ->
      Store.put(name, task("cas-1", "ctx"))
    end
  end

  test "the verified credential and node-local stream are never written to disk",
       %{name: name, data_dir: data_dir} do
    owner = AshA2A.Transport.Runtime.owner_key()

    working = %{
      task("auth-1", "ctx-auth", :working)
      | metadata: %{
          "a2a.auth" => %{identity: %{sub: "u1", token: "SECRET-BEARER-TOKEN"}},
          owner => "principal:u1",
          :stream => Stream.map([1], & &1),
          "keep" => "me"
        }
    }

    assert :ok = Store.put(name, working)

    # Raw EKV read (not through the store) -- what is actually persisted.
    persisted = EKV.get(name, "a2a_task/auth-1")
    refute Map.has_key?(persisted.metadata, "a2a.auth")
    refute Map.has_key?(persisted.metadata, :stream)
    assert persisted.metadata[owner] == "principal:u1"
    assert persisted.metadata["keep"] == "me"

    # And the token bytes are absent from the on-disk files themselves.
    assert :ok = stop_supervised({EKV, name})

    on_disk =
      data_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map_join(&File.read!/1)

    refute on_disk =~ "SECRET-BEARER-TOKEN"
    assert on_disk =~ "principal:u1"
  end

  test "child_spec fails closed without an explicit data_dir" do
    assert_raise ArgumentError, ~r/requires an explicit :data_dir/, fn ->
      Store.child_spec(name: :no_dir)
    end

    assert_raise ArgumentError, ~r/requires :name/, fn ->
      Store.child_spec(data_dir: "/tmp/x")
    end
  end
end

# --- SECTION 14: Original test/ash_a2a/w608_map_update_court_test.exs ---
defmodule AshA2A.W608MapUpdateCourtTest do
  @moduledoc """
  Lane W608 (v26.10.7, WP-4 / OS-20) Map.update sweep court.

  Parameterized deterministic insertion across populated and empty baselines,
  run twice, over real Map.update-family insertion sites in real modules.

  The W606 rubric splits sites into class (a) absent-key-critical (patched to
  an explicit branch) and class (b) default-intended (left, disclosed). This
  court pins the observable contract of both shapes:

    * a class-(b) accumulator `Map.update(acc, k, default, fun)` must insert
      the default verbatim on an absent key (the fun is NOT applied to the
      default); every class-(b) accumulator site in lib/ is idempotent-fun
      (fun(default) == default), so its result is identical under either
      Map.update/4 absent-key semantics the OS-20 hazard names;
    * a dual-safe explicit-branch site (Protocol.Agent.State.track_context/2)
      must insert the default unmodified on the first insert and prepend
      exactly once per insert thereafter.

  No mocks: real ETS (AllocationCounters), a real Agent (MemoryClaimStore),
  and a pure struct (Protocol.Agent.State).
  """

  use ExUnit.Case, async: true

  alias AshA2A.C2.MemoryClaimStore
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Telemetry.AllocationCounters

  @sites [:allocation_counters, :agent_state_track_context, :claim_store]

  test "deterministic insertion across empty and populated baselines, x2 runs" do
    for run <- [1, 2] do
      for site <- @sites do
        key = "w608-#{run}-#{site}"

        empty = insert(site, key)

        assert empty == expected(site, key, :empty),
               "site #{site} run #{run}: empty-baseline diverged: #{inspect(empty)}"

        populated = insert_populated(site, key)

        assert populated == expected(site, key, :populated),
               "site #{site} run #{run}: populated-baseline diverged: #{inspect(populated)}"
      end
    end
  end

  test "absent-key default stored verbatim (no fun application), x2 runs" do
    for run <- [1, 2] do
      tid = AllocationCounters.new()
      handler = AllocationCounters.attach!(tid, make_ref(), owner: self())

      try do
        emit_allocation("w608-verbatim-#{run}", :llm)
        assert AllocationCounters.counts(tid) == %{"w608-verbatim-#{run}" => %{llm: 1}}

        emit_allocation("w608-verbatim-#{run}", :llm)
        assert AllocationCounters.counts(tid) == %{"w608-verbatim-#{run}" => %{llm: 2}}
      after
        AllocationCounters.detach(handler)
      end
    end
  end

  # --- parameterized site drivers ------------------------------------------

  defp insert(:allocation_counters, key) do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    emit_allocation(key, :llm)
    counts = AllocationCounters.counts(tid)
    AllocationCounters.detach(handler)
    counts
  end

  defp insert_populated(:allocation_counters, key) do
    tid = AllocationCounters.new()
    handler = AllocationCounters.attach!(tid, make_ref(), owner: self())
    emit_allocation(key, :machinery)
    emit_allocation(key, :llm)
    counts = AllocationCounters.counts(tid)
    AllocationCounters.detach(handler)
    counts
  end

  defp insert(:agent_state_track_context, key) do
    %State{}
    |> State.track_context(%{context_id: key, id: "task-first"})
    |> Map.get(:contexts)
  end

  defp insert_populated(:agent_state_track_context, key) do
    %State{}
    |> State.track_context(%{context_id: key, id: "task-prior"})
    |> State.track_context(%{context_id: key, id: "task-new"})
    |> Map.get(:contexts)
  end

  defp insert(:claim_store, key) do
    ensure_claim_store()
    MemoryClaimStore.complete(key, {:approved, :w608})
    Agent.get(MemoryClaimStore, &Map.get(&1, key))
  end

  defp insert_populated(:claim_store, key) do
    ensure_claim_store()
    claim_key = "#{key}-prior"
    :ok = MemoryClaimStore.claim(claim_key, "g-prior")
    MemoryClaimStore.complete(claim_key, {:approved, :w608})
    Agent.get(MemoryClaimStore, &Map.get(&1, claim_key))
  end

  # --- exact expected results -----------------------------------------------

  defp expected(:allocation_counters, key, :empty), do: %{key => %{llm: 1}}

  defp expected(:allocation_counters, key, :populated),
    do: %{key => %{machinery: 1, llm: 1}}

  defp expected(:agent_state_track_context, key, :empty),
    do: %{key => ["task-first"]}

  defp expected(:agent_state_track_context, key, :populated),
    do: %{key => ["task-new", "task-prior"]}

  defp expected(:claim_store, _key, :empty),
    do: {0, {:completed, {:approved, :w608}}}

  defp expected(:claim_store, _key, :populated),
    do: {"g-prior", {:completed, {:approved, :w608}}}

  # --- helpers ---------------------------------------------------------------

  defp emit_allocation(class, resolver) do
    :telemetry.execute([:ash_a2a, :semantic, :allocation], %{}, %{
      class: class,
      resolver: resolver
    })
  end

  defp ensure_claim_store do
    case MemoryClaimStore.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
