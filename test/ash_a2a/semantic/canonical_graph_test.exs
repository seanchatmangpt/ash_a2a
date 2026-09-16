defmodule AshA2A.Semantic.CanonicalGraphTest do
  @moduledoc """
  Real RFC S12 canonical graph identity contract, exercised against the real
  `:rdf` (RDF.ex 3.0.1) canonicalizer -- no doubles of any kind.

  Every fixture in this module is a minimal reproducing input from the
  adversarial verification of the v26.9.16 SA2A branches. Each one reproduced a
  real defect in the praxis-graphlaw wasm `graph_hash` export that three
  branches nonetheless described as RDFC-1.0 / S12-conformant. These tests pin
  the corrected behaviour so the false claim cannot silently return.

  The measured GraphLaw digests those fixtures produce are recorded in
  `docs/explanation/canonical-graph-identity.md` and asserted, where the
  vendored wasm law package is available, in
  `AshA2A.Semantic.CanonicalGraphThreeWayAgreementTest`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalGraph

  doctest AshA2A.Semantic.CanonicalGraph

  # The three vendored graphlaw fixtures, verbatim.
  @base "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @reordered "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"
  @mutated "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:ZZZ .\n"

  # The verifier's blank-node relabeling pair: the same graph, differing only
  # in the *name* of its one blank node.
  @blank_b1 "@prefix ex: <http://example.org/> .\nex:a ex:p _:b1 .\n_:b1 ex:p ex:c .\n"
  @blank_zzz9 "@prefix ex: <http://example.org/> .\nex:a ex:p _:zzz9 .\n_:zzz9 ex:p ex:c .\n"

  # Real measured values (RDF.ex 3.0.1, RDFC-1.0 + SHA-256 over sorted N-Quads).
  @digest_base "09be9b797c5854a65e9568cbfeb7a9435e8ce690bb8c67a299ac7e7c3b4e2efa"
  @digest_mutated "dff591ad4525e7884f91a8ddc118890d55c17f1acd1155eaa8e3414ed3a21e34"
  @digest_blank "3c2f833bf34d489b97894abd575e4a8ac8d6b89564ee074ed45492402f278e5c"
  @digest_empty "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  describe "canonical_digest/1 invariance" do
    test "is invariant under prefix relabeling and triple reordering" do
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(@base)
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(@reordered)
    end

    test "is invariant under blank-node relabeling -- the graphlaw defect this corrects" do
      # praxis-graphlaw v26.7.5 graph_hash gives these two DIFFERENT digests
      # (98d6f0bb... and fa6b931d...). RDFC-1.0 gives one digest, because they
      # are the same graph.
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(@blank_b1)
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(@blank_zzz9)

      assert CanonicalGraph.canonical_digest(@blank_b1) ==
               CanonicalGraph.canonical_digest(@blank_zzz9)
    end

    test "discriminates a genuinely different graph" do
      assert {:ok, @digest_mutated} = CanonicalGraph.canonical_digest(@mutated)
      refute @digest_mutated == @digest_base
    end

    test "accepts an already-parsed RDF.Graph and agrees with the Turtle form" do
      {:ok, graph} = CanonicalGraph.parse(@base)
      assert %RDF.Graph{} = graph
      assert {:ok, @digest_base} = CanonicalGraph.canonical_digest(graph)
    end
  end

  describe "canonical_digest/1 fails closed" do
    test "unparseable input is a typed error, NOT the empty-graph digest" do
      # This is the second graphlaw defect: graph_hash("@@@ not turtle")
      # returns graph_hash("") -- the BLAKE3 empty digest af1349b9... -- so a
      # garbage document and an empty document are indistinguishable.
      assert {:error, {:parse_error, message}} =
               CanonicalGraph.canonical_digest("@@@ not turtle")

      assert message =~ "Turtle scanner error"

      # And the empty graph still has its own real, distinct digest.
      assert {:ok, @digest_empty} = CanonicalGraph.canonical_digest("")
      refute {:ok, @digest_empty} == CanonicalGraph.canonical_digest("@@@ not turtle")
    end

    test "a lone 0xFF byte is refused before any parser sees it" do
      # The verifier's minimal reproducing input for the wasm marshalling
      # defect: AshA2A.GraphLaw.Wasm.graph_hash/3 guards only is_binary/1, but
      # the Rust export takes a &str, and this single byte makes the engine
      # commit 2,148,270,080 bytes and permanently poison the instance.
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.canonical_digest(<<0xFF>>)
    end

    test "an invalid byte inside otherwise valid Turtle is refused, at its real offset" do
      poisoned = @base <> <<0xFF>>

      assert {:error, {:invalid_encoding, offset}} = CanonicalGraph.canonical_digest(poisoned)
      assert offset == byte_size(@base)
    end

    test "a non-binary, non-graph term is refused rather than coerced" do
      assert {:error, {:unsupported_input, _}} = CanonicalGraph.canonical_digest(:not_a_graph)
      assert {:error, {:unsupported_input, _}} = CanonicalGraph.canonical_digest(%{a: 1})
    end

    test "ensure_utf8/1 reports the offset of the first invalid byte" do
      assert :ok = CanonicalGraph.ensure_utf8(@base)
      assert :ok = CanonicalGraph.ensure_utf8("ünïcödé is fine")
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.ensure_utf8(<<0xFF>>)
      assert {:error, {:invalid_encoding, 2}} = CanonicalGraph.ensure_utf8(<<"ok", 0xFF>>)
      # "héllo" is 6 bytes, not 5 -- the offset is a real byte offset, not a
      # grapheme index, which is exactly what a wasm &str marshaller needs.
      assert 6 == byte_size("héllo")

      assert {:error, {:invalid_encoding, 6}} =
               CanonicalGraph.ensure_utf8(<<"héllo"::utf8, 0xC0>>)
    end

    test "canonical_digest!/1 raises with the typed reason instead of returning a digest" do
      assert @digest_base == CanonicalGraph.canonical_digest!(@base)

      assert_raise ArgumentError, ~r/not valid UTF-8 \(first invalid byte at offset 0\)/, fn ->
        CanonicalGraph.canonical_digest!(<<0xFF>>)
      end

      assert_raise ArgumentError, ~r/not well-formed Turtle/, fn ->
        CanonicalGraph.canonical_digest!("@@@ not turtle")
      end
    end
  end

  describe "canonical_nquads/1" do
    test "returns the exact byte string the digest is taken over" do
      assert {:ok, nquads} = CanonicalGraph.canonical_nquads(@base)

      assert nquads ==
               "<http://example.org/a> <http://example.org/p> <http://example.org/b> .\n" <>
                 "<http://example.org/b> <http://example.org/p> <http://example.org/c> .\n"

      assert @digest_base ==
               :sha256 |> :crypto.hash(nquads) |> Base.encode16(case: :lower)
    end

    test "relabels blank nodes to canonical c14n identifiers" do
      assert {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)

      assert nquads ==
               "<http://example.org/a> <http://example.org/p> _:c14n0 .\n" <>
                 "_:c14n0 <http://example.org/p> <http://example.org/c> .\n"

      # Byte-identical for the relabeled variant -- this is what makes
      # feeding canonical N-Quads to a second engine meaningful.
      assert CanonicalGraph.canonical_nquads(@blank_b1) ==
               CanonicalGraph.canonical_nquads(@blank_zzz9)
    end

    test "fails closed on the same inputs canonical_digest/1 refuses" do
      assert {:error, {:parse_error, _}} = CanonicalGraph.canonical_nquads("@@@ not turtle")
      assert {:error, {:invalid_encoding, 0}} = CanonicalGraph.canonical_nquads(<<0xFF>>)
    end

    test "canonical N-Quads round-trip to the same digest" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@blank_b1)
      assert {:ok, @digest_blank} = CanonicalGraph.canonical_digest(nquads)
    end
  end

  describe "algorithm identity, as pinned by the Root Manifest" do
    test "names the real algorithm and hash function" do
      assert "RDFC-1.0" == CanonicalGraph.algorithm()
      assert "SHA-256" == CanonicalGraph.hash_function()
      assert "application/n-quads; sorted=code-point" == CanonicalGraph.serialization()
      assert "RDFC-1.0/SHA-256/n-quads-sorted" == CanonicalGraph.algorithm_id()
      assert "text/turtle" == CanonicalGraph.input_media_type()
    end

    test "the named hash function is the one actually applied" do
      {:ok, nquads} = CanonicalGraph.canonical_nquads(@mutated)
      {:ok, digest} = CanonicalGraph.canonical_digest(@mutated)

      assert digest == :sha256 |> :crypto.hash(nquads) |> Base.encode16(case: :lower)
    end

    test "the digest is NOT BLAKE3 of the input, which is what graphlaw computes" do
      # graphlaw's graph_hash is BLAKE3 over its own sorted serialization; the
      # empty-graph digests of the two engines are therefore different, and a
      # receipt must say which one it means.
      assert {:ok, @digest_empty} = CanonicalGraph.canonical_digest("")
      graphlaw_empty = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
      refute @digest_empty == graphlaw_empty
    end
  end
end
