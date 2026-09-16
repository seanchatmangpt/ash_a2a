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
      check all(a <- label_generator(), b <- label_generator(), a != b) do
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
