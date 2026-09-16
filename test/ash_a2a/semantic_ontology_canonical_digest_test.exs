defmodule AshA2A.SemanticOntologyCanonicalDigestTest do
  @moduledoc """
  Tests the real canonical digest path added to `AshA2A.Semantic.Ontology`
  (RFC-SA2A-001 S12), and pins the precise limitation of the pre-existing
  `:fingerprint` field that motivated adding it.

  Real engine, real subprocess, real N-Triples on the wire. No mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.GraphLaw.WasmDriver
  alias AshA2A.Semantic.{IR, Ontology}

  @engine_skip (if AshA2A.GraphLaw.WasmDriver.available?() do
                  false
                else
                  "praxis-graphlaw wasm engine unavailable at " <>
                    AshA2A.GraphLaw.WasmDriver.wasm_path()
                end)

  defp triples do
    [
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
        object: "urn:ash-a2a:semantic:entities"
      },
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "https://schema.org/description",
        object: "a plain literal, with \"quotes\" and a\nnewline"
      },
      %{
        subject: "urn:ash-a2a:semantic:node:alpha",
        predicate: "http://www.w3.org/ns/prov#wasDerivedFrom",
        object: "urn:ash-a2a:source:s1"
      }
    ]
  end

  describe "to_ntriples/1 (pure)" do
    test "writes absolute-IRI objects as IRIs and everything else as literals" do
      nt = Ontology.to_ntriples(triples())

      assert nt =~
               "<urn:ash-a2a:semantic:node:alpha> <http://www.w3.org/ns/prov#wasDerivedFrom> <urn:ash-a2a:source:s1> .\n"

      assert nt =~
               ~s(<https://schema.org/description> "a plain literal, with \\"quotes\\" and a\\nnewline" .)

      # Every line is a terminated N-Triples statement.
      lines = nt |> String.split("\n", trim: true)
      assert length(lines) == 3
      assert Enum.all?(lines, &String.ends_with?(&1, " ."))
    end

    test "a scheme-prefixed string containing IRI-forbidden characters stays a literal" do
      nt =
        Ontology.to_ntriples([
          %{subject: "urn:s", predicate: "urn:p", object: "http://example.org/a b"}
        ])

      assert nt == ~s(<urn:s> <urn:p> "http://example.org/a b" .\n)
    end

    test "accepts an %Ontology{} struct as well as a bare triple list" do
      ontology = %Ontology{source_id: "s1", triples: triples(), fingerprint: "unused"}
      assert Ontology.to_ntriples(ontology) == Ontology.to_ntriples(triples())
    end
  end

  describe "canonical_digest/1 against the real engine" do
    @describetag skip: @engine_skip

    test "is a real 64-hex canonical digest and is triple-order invariant" do
      assert {:ok, a} = Ontology.canonical_digest(triples())
      assert {:ok, b} = Ontology.canonical_digest(Enum.reverse(triples()))

      assert String.match?(a, ~r/^[0-9a-f]{64}$/)

      assert a == b,
             "canonical_digest must not depend on triple order, got #{a} vs #{b}"
    end

    test "a genuinely different graph gets a different digest" do
      {:ok, a} = Ontology.canonical_digest(triples())

      mutated =
        List.update_at(triples(), 2, &Map.put(&1, :object, "urn:ash-a2a:source:s2"))

      {:ok, b} = Ontology.canonical_digest(mutated)
      refute a == b
    end

    test "canonical_digest agrees with running graph_hash on the N-Triples directly" do
      {:ok, via_module} = Ontology.canonical_digest(triples())
      {:ok, via_engine} = WasmDriver.graph_hash(Ontology.to_ntriples(triples()))
      assert via_module == via_engine
    end

    test "a real projection built from real admitted IR gets a canonical digest" do
      ir = %IR{
        source_id: "src-canonical",
        standing: :admitted,
        authority: :none,
        entities: [
          %{"id" => "e1", "kind" => "entity", "type" => "schema:Thing", "description" => "first"},
          %{"id" => "e2", "kind" => "entity", "type" => "schema:Thing", "description" => "second"}
        ]
      }

      assert {:ok, %Ontology{} = ontology} = Ontology.from_ir(ir)
      assert {:ok, digest} = Ontology.canonical_digest(ontology)
      assert String.match?(digest, ~r/^[0-9a-f]{64}$/)

      # The two digests answer different questions and must not be conflated.
      refute digest == ontology.fingerprint
    end
  end

  describe "the fingerprint limitation this work exists to name" do
    test "fingerprint is still populated and unchanged in shape (64 lowercase hex, sha256)" do
      ir = %IR{
        source_id: "src-fp",
        standing: :admitted,
        authority: :none,
        entities: [%{"id" => "e1", "kind" => "entity"}],
        relations: []
      }

      assert {:ok, %Ontology{fingerprint: fp}} = Ontology.from_ir(ir)
      assert String.match?(fp, ~r/^[0-9a-f]{64}$/)
    end

    @tag skip: @engine_skip
    test "canonical_digest has RDF set semantics that a sort-then-hash over a list cannot" do
      # An RDF graph is a SET of triples. A duplicated triple denotes the
      # same graph, so the canonical digest must be unchanged -- while the
      # underlying Erlang term list, which is what `:fingerprint` hashes, is
      # demonstrably different. This is the concrete gap that makes
      # `:fingerprint` unusable as portable S12 identity.
      base = triples()
      duplicated = base ++ [List.first(base)]

      refute :erlang.term_to_binary(Enum.sort(base)) ==
               :erlang.term_to_binary(Enum.sort(duplicated))

      assert {:ok, a} = Ontology.canonical_digest(base)
      assert {:ok, b} = Ontology.canonical_digest(duplicated)

      assert a == b,
             "a duplicated triple denotes the same RDF graph, got #{a} vs #{b}"
    end

    @tag skip: @engine_skip
    test "MEASURED ENGINE LIMITATION: graph_hash itself is duplicate-sensitive on the wire" do
      # Recorded, not assumed. Handing the engine the same N-Triples
      # statement twice produces a DIFFERENT digest than handing it once,
      # even though both documents denote the same RDF graph. This is the
      # sole reason `to_ntriples/1` emits a deduplicated statement set.
      #
      # Falsifier: if a future engine version makes these two digests equal,
      # this test fails, and the dedup in `to_ntriples/1` becomes redundant
      # (harmless, but the moduledoc's justification should then be updated).
      one = "<urn:s> <urn:p> <urn:o> .\n"
      twice = one <> one

      assert {:ok, digest_one} = WasmDriver.graph_hash(one)
      assert {:ok, digest_twice} = WasmDriver.graph_hash(twice)

      refute digest_one == digest_twice,
             "engine is now duplicate-invariant; see this test's falsifier note"
    end

    test "canonical_digest reports a typed error when the engine is absent" do
      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               Ontology.canonical_digest(triples(), wasm_path: "/nonexistent/x.wasm")
    end
  end
end
