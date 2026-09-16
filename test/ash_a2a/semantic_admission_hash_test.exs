defmodule AshA2A.SemanticAdmissionHashTest do
  @moduledoc """
  Chicago-school tests for RFC-SA2A-001 S12/S31/S33/S52/S60.

  Every digest asserted here came out of the REAL `praxis-graphlaw` wasm
  module executed in a REAL subprocess. Nothing is mocked, stubbed or
  hand-computed in Elixir. Where the engine artifact is absent the tests
  produce a NAMED, VISIBLE SKIP rather than substituting a fake engine --
  a mocked hash would certify nothing at all, which is the entire point of
  the admission hash.

  The chain is anchored to an external constant: `blake3_hex("abc")` is
  asserted against the published BLAKE3 test vector, so a silently-wrong
  engine cannot pass these tests just by being self-consistent.
  """
  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.WasmDriver
  alias AshA2A.Semantic.AdmissionHash

  doctest AshA2A.Semantic.AdmissionHash

  # Published BLAKE3 test vector for the 3-byte input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  @base_ttl """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  # Same graph: different prefix LABEL and different triple ORDER.
  @relabelled_ttl """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  # One triple genuinely changed.
  @mutated_ttl """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:ZZZ .
  """

  @validators ["shacl-core", "shex-2.1"]
  @rules ["n3-log-implies", "owl-rl"]
  @profile "sa2a/profile/strict"

  # Evaluated at compile time so the engine-backed tests can produce a NAMED,
  # VISIBLE ExUnit skip (with the resolved path in the reason) instead of
  # silently degrading to a fabricated engine.
  @engine_skip (if AshA2A.GraphLaw.WasmDriver.available?() do
                  false
                else
                  "praxis-graphlaw wasm engine unavailable at " <>
                    AshA2A.GraphLaw.WasmDriver.wasm_path() <>
                    " (set GRAPHLAW_WASM_PATH or config :ash_a2a, :graphlaw_wasm_path)"
                end)

  describe "encoding (pure, no engine required)" do
    test "netstring framing is prefix-free" do
      assert AdmissionHash.netstring("abc") == "3:abc,"
      assert AdmissionHash.netstring("") == "0:,"
      # A netstring carrying its own framing characters is still unambiguous.
      assert AdmissionHash.netstring("3:x,") == "4:3:x,,"
    end

    test "THE BOUNDARY CASE: a byte cannot migrate across a component boundary" do
      # Under naive `Validators || Rules` concatenation these two genuinely
      # different admissions both produce the preimage "abc" and therefore
      # collide. Length-prefixing must separate them.
      a_validators = AdmissionHash.validators_preimage(["a"], :preserved_order)
      a_rules = AdmissionHash.rules_preimage(["bc"], :preserved_order)

      b_validators = AdmissionHash.validators_preimage(["ab"], :preserved_order)
      b_rules = AdmissionHash.rules_preimage(["c"], :preserved_order)

      refute a_validators <> a_rules == b_validators <> b_rules
      refute a_validators == b_validators
      refute a_rules == b_rules
    end

    test "list element boundaries are injective" do
      refute AdmissionHash.validators_preimage(["a", "bc"], :preserved_order) ==
               AdmissionHash.validators_preimage(["ab", "c"], :preserved_order)

      refute AdmissionHash.validators_preimage(["a,b"], :preserved_order) ==
               AdmissionHash.validators_preimage(["a", "b"], :preserved_order)
    end

    test "domain separation: identical content in different components differs" do
      refute AdmissionHash.validators_preimage(["x"]) == AdmissionHash.rules_preimage(["x"])
      refute AdmissionHash.rules_preimage(["x"]) == AdmissionHash.profile_preimage("x")
    end

    test "validators and rules default to set semantics; order can be preserved" do
      assert AdmissionHash.validators_preimage(["b", "a"]) ==
               AdmissionHash.validators_preimage(["a", "b"])

      assert AdmissionHash.validators_preimage(["a", "a", "b"]) ==
               AdmissionHash.validators_preimage(["a", "b"])

      refute AdmissionHash.validators_preimage(["b", "a"], :preserved_order) ==
               AdmissionHash.validators_preimage(["a", "b"], :preserved_order)
    end

    test "map profile key/value boundaries are injective and key-order-free" do
      assert AdmissionHash.profile_preimage(%{"a" => "1", "b" => "2"}) ==
               AdmissionHash.profile_preimage(%{"b" => "2", "a" => "1"})

      refute AdmissionHash.profile_preimage(%{"ab" => "c"}) ==
               AdmissionHash.profile_preimage(%{"a" => "bc"})
    end

    test "composite preimage frames all four component digests in a fixed order" do
      preimage = AdmissionHash.composite_preimage("g", "v", "r", "p")

      assert preimage ==
               "sa2a-admission-hash/v1\n" <>
                 "5:graph,1:g,10:validators,1:v,5:rules,1:r,7:profile,1:p,"

      # Swapping which component a digest belongs to changes the preimage.
      refute preimage == AdmissionHash.composite_preimage("v", "g", "r", "p")
    end

    test "components/0 fixes the composite order" do
      assert AdmissionHash.components() == [:graph, :validators, :rules, :profile]
    end
  end

  describe "real engine" do
    @describetag :graphlaw
    @describetag skip: @engine_skip

    test "blake3_hex is anchored to the published BLAKE3 vector for \"abc\"" do
      assert {:ok, @blake3_abc} = WasmDriver.blake3_hex("abc")
    end

    test "engine reports its version through the real subprocess" do
      assert {:ok, version} = WasmDriver.version()
      assert String.starts_with?(version, "praxis-graphlaw")
    end

    test "canonical_graph_digest is invariant under prefix relabelling and triple reorder" do
      assert {:ok, base} = AdmissionHash.canonical_graph_digest(@base_ttl)
      assert {:ok, relabelled} = AdmissionHash.canonical_graph_digest(@relabelled_ttl)
      assert {:ok, mutated} = AdmissionHash.canonical_graph_digest(@mutated_ttl)

      assert base == relabelled,
             "graph digest must be prefix-label and triple-order invariant, " <>
               "got #{base} vs #{relabelled}"

      refute base == mutated
      assert String.match?(base, ~r/^[0-9a-f]{64}$/)
    end

    test "canonical_graph_digest of a malformed document does not collide with the empty graph" do
      assert {:ok, empty} = AdmissionHash.canonical_graph_digest("")
      assert {:ok, malformed} = AdmissionHash.canonical_graph_digest("not turtle at all {{{")

      # Measured behaviour: the engine returns a digest rather than an
      # error for unparsable input, but it is NOT the empty-graph digest.
      # Asserted so a future engine change that silently collapses garbage
      # to the empty graph -- which would let a peer pass conformance with
      # no semantic state at all -- fails loudly here.
      refute empty == malformed
    end

    test "admission_hash binds all four components and is reproducible" do
      assert {:ok, h1} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      assert {:ok, h2} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      assert AdmissionHash.agree?(h1, h2)
      assert AdmissionHash.differing_components(h1, h2) == []
      assert String.match?(h1.admission_hash, ~r/^[0-9a-f]{64}$/)
      assert h1.encoding == "sa2a-admission-hash/v1"
      assert h1.algorithm == "blake3"
      assert h1.normalization == :sorted_set
      assert String.starts_with?(h1.engine_version, "praxis-graphlaw")
    end

    test "the composite hash is exactly BLAKE3 of the documented preimage" do
      assert {:ok, h} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      preimage =
        AdmissionHash.composite_preimage(
          h.graph_digest,
          h.validators_digest,
          h.rules_digest,
          h.profile_digest
        )

      assert {:ok, recomputed} = WasmDriver.blake3_hex(preimage)

      assert recomputed == h.admission_hash,
             "a verifier holding only the four component digests must be able to " <>
               "rebuild the composite; got #{recomputed} vs #{h.admission_hash}"
    end

    test "each of the four components independently changes the admission hash" do
      {:ok, base} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)

      {:ok, other_graph} =
        AdmissionHash.admission_hash(@mutated_ttl, @validators, @rules, @profile)

      {:ok, other_validators} =
        AdmissionHash.admission_hash(@base_ttl, ["shacl-core"], @rules, @profile)

      {:ok, other_rules} =
        AdmissionHash.admission_hash(@base_ttl, @validators, ["owl-rl"], @profile)

      {:ok, other_profile} =
        AdmissionHash.admission_hash(@base_ttl, @validators, @rules, "sa2a/profile/lax")

      for {label, variant} <- [
            graph: other_graph,
            validators: other_validators,
            rules: other_rules,
            profile: other_profile
          ] do
        refute base.admission_hash == variant.admission_hash,
               "changing #{label} must change the admission hash"

        assert AdmissionHash.differing_components(base, variant) == [label],
               "changing #{label} must localise to exactly that component, got " <>
                 inspect(AdmissionHash.differing_components(base, variant))

        refute AdmissionHash.agree?(base, variant)
      end
    end

    test "a graph that is only relabelled does NOT change the admission hash" do
      {:ok, a} = AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile)
      {:ok, b} = AdmissionHash.admission_hash(@relabelled_ttl, @validators, @rules, @profile)

      # This is the S12 property the whole conformance claim rests on: two
      # peers that serialised the same O* differently still agree. Scope:
      # prefix labels and triple order only -- blank-node relabelling is not
      # covered (see the MEASURED ENGINE LIMITATION test below).
      assert AdmissionHash.agree?(b, a)
    end

    test "differing_components flags an incomparable normalization" do
      {:ok, sorted} =
        AdmissionHash.admission_hash(@base_ttl, ["b", "a"], @rules, @profile)

      {:ok, ordered} =
        AdmissionHash.admission_hash(@base_ttl, ["b", "a"], @rules, @profile,
          preserve_order: true
        )

      assert :normalization_mismatch in AdmissionHash.differing_components(sorted, ordered)
      refute AdmissionHash.agree?(sorted, ordered)
    end

    test "MEASURED ENGINE LIMITATION: a blank-node relabel changes graph_digest (not RDFC-1.0)" do
      # Recorded, not assumed. The same one-triple graph written with `_:b1`
      # and with `_:zzz9` is one RDF graph under RDFC-1.0 -- RDF.ex's in-BEAM
      # `RDF.Graph.canonical_hash/1` (the RFC S12 identity
      # `AshA2A.Semantic.AdmissionPipeline` uses) gives one digest for both --
      # but the engine's `graph_hash`, which this admission hash is wired to,
      # gives two. Two peers holding the same O* under different blank-node
      # labels therefore disagree on `h`, localised to `[:graph]`.
      #
      # Falsifier: if the engine becomes blank-node canonical, the first
      # `refute` fails and the "not RDFC-1.0" wording in AdmissionHash,
      # Ontology and WasmDriver docs must be revisited.
      b1 = "@prefix ex: <http://example.org/> .\n_:b1 ex:p ex:o .\n"
      zzz9 = "@prefix ex: <http://example.org/> .\n_:zzz9 ex:p ex:o .\n"

      {:ok, g1} = RDF.Turtle.read_string(b1)
      {:ok, g2} = RDF.Turtle.read_string(zzz9)
      assert RDF.Graph.canonical_hash(g1) == RDF.Graph.canonical_hash(g2)

      assert {:ok, d1} = AdmissionHash.canonical_graph_digest(b1)
      assert {:ok, d2} = AdmissionHash.canonical_graph_digest(zzz9)
      refute d1 == d2, "engine graph_hash is now blank-node canonical; see falsifier note"

      {:ok, h1} = AdmissionHash.admission_hash(b1, @validators, @rules, @profile)
      {:ok, h2} = AdmissionHash.admission_hash(zzz9, @validators, @rules, @profile)
      assert AdmissionHash.differing_components(h1, h2) == [:graph]
    end
  end

  describe "typed failure when the engine is absent" do
    test "a missing wasm artifact is a typed error, never a fabricated digest" do
      assert {:error, %{code: :graphlaw_wasm_not_found, path: path}} =
               AdmissionHash.canonical_graph_digest(@base_ttl,
                 wasm_path: "/nonexistent/praxis_graphlaw_wasm_bg.wasm"
               )

      assert path == "/nonexistent/praxis_graphlaw_wasm_bg.wasm"

      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               AdmissionHash.admission_hash(@base_ttl, @validators, @rules, @profile,
                 wasm_path: "/nonexistent/praxis_graphlaw_wasm_bg.wasm"
               )
    end

    @tag skip: @engine_skip
    test "an unknown engine export is a typed error" do
      assert {:ok, [{:error, %{code: :graphlaw_call_error}}]} =
               WasmDriver.call_many([{"definitely_not_an_export", []}])
    end
  end
end
