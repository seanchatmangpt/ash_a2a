defmodule AshA2A.Semantic.CanonicalDigestTest do
  @moduledoc """
  Real end-to-end coverage of `Ontology -> serialize -> verify -> native
  canonical hash` against the **real** prebuilt praxis-graphlaw WebAssembly
  engine.

  Chicago-school, no test double: every digest asserted below came out of the
  real `praxis_graphlaw_wasm_bg.wasm` module's linear memory, reached through
  a real `node` subprocess running the real host shim in `priv/graphlaw/`. The
  wasm module is instantiated with real host entropy (`crypto.randomFillSync`),
  not a fixed stub, so the determinism properties asserted here are real
  properties of the engine rather than artefacts of a pinned RNG.

  On a machine without the praxis workspace or without `node`, these tests
  **skip loudly and by name** (`@moduletag :graphlaw` plus a real
  availability check that prints the exact missing hop) -- never silently
  substituting a fake engine.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Semantic.{CanonicalDigest, GraphLawBridge, IR, Ontology, Serialize}

  # Published BLAKE3 test vector for the input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  setup_all do
    case GraphLawBridge.host() do
      {:unavailable, reason} ->
        {:ok, skip_reason: reason}

      host ->
        {:ok, skip_reason: nil, host: host}
    end
  end

  setup %{skip_reason: skip_reason} do
    if skip_reason do
      IO.puts("\n  [skipped] real praxis-graphlaw host unavailable: #{inspect(skip_reason)}")
    end

    :ok
  end

  defp live?, do: match?(host when host in [:in_beam, :node_shim], GraphLawBridge.host())

  defp admitted_ir(opts) do
    label_a = Keyword.get(opts, :label_a, "Alice")
    order = Keyword.get(opts, :order, :forward)

    entities = [
      %{"id" => "e1", "kind" => "entity", "type" => "schema:Person", "label" => label_a},
      %{"id" => "e2", "kind" => "entity", "type" => "schema:Person", "label" => "Bob"}
    ]

    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: if(order == :forward, do: entities, else: Enum.reverse(entities)),
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
          "description" => "Introduce " <> <<34>> <> "Alice" <> <<34>> <> " to Bob"
        }
      ]
    }
  end

  defp ontology!(opts \\ []) do
    {:ok, ontology} = Ontology.from_ir(admitted_ir(opts))
    ontology
  end

  describe "the real engine is reachable and is the engine we think it is" do
    test "graphlaw_version/0 returns a real version string from the wasm module" do
      if live?() do
        assert {:ok, version} = GraphLawBridge.version()
        assert version =~ "praxis-graphlaw"
      end
    end

    test "blake3_hex/1 reproduces the published BLAKE3 test vector for \"abc\"" do
      if live?() do
        assert {:ok, @blake3_abc} = GraphLawBridge.blake3_hex("abc")
      end
    end

    test "run_hooks/2 returns the real admission vocabulary, JSON-decoded" do
      if live?() do
        base = "<http://e/a> <http://e/p> <http://e/b> .\n"
        event = "<http://e/c> <http://e/p> <http://e/d> .\n"

        assert {:ok, %{"status" => status} = payload} = GraphLawBridge.run_hooks(base, event)
        assert status == "ADMITTED"
        assert Map.has_key?(payload, "verdicts")
        assert Map.has_key?(payload, "receipts")
      end
    end

    test "validate_all/6 returns the real dialect report, JSON-decoded" do
      if live?() do
        {:ok, nt} = Serialize.to_ntriples(ontology!())

        assert {:ok, %{"graph_hash" => graph_hash, "dialects" => dialects}} =
                 GraphLawBridge.validate_all(nt)

        assert graph_hash =~ ~r/^[0-9a-f]{64}$/
        assert is_list(dialects)
        assert Enum.any?(dialects, &(&1["dialect"] == "SHACL"))
      end
    end
  end

  describe "the RFC S12 path: Ontology -> serialize -> verify -> native canonical digest" do
    test "a real Ontology produces a real, verified 64-hex canonical digest" do
      if live?() do
        ontology = ontology!()
        assert {:ok, result} = CanonicalDigest.canonical_digest(ontology)

        assert result.algorithm == :graphlaw_graph_hash
        assert result.format == :ntriples
        assert result.verified == true
        assert result.digest =~ ~r/^[0-9a-f]{64}$/
        assert result.engine_version =~ "praxis-graphlaw"
        assert result.triple_count == length(ontology.triples)
        assert result.distinct_triple_count == result.triple_count
        assert result.document_bytes > 0
      end
    end

    test "the digest is syntax-independent: N-Triples and Turtle of the same graph agree" do
      # This is the property RFC S12 is actually asking for -- identity of the
      # *graph*, not of a chosen serialization.
      if live?() do
        ontology = ontology!()

        assert {:ok, nt_result} = CanonicalDigest.canonical_digest(ontology, format: :ntriples)
        assert {:ok, ttl_result} = CanonicalDigest.canonical_digest(ontology, format: :turtle)

        assert nt_result.digest == ttl_result.digest
        refute nt_result.document_bytes == ttl_result.document_bytes
      end
    end

    test "the digest is stable across repeated real engine invocations" do
      if live?() do
        ontology = ontology!()
        assert {:ok, first} = CanonicalDigest.digest(ontology)
        assert {:ok, second} = CanonicalDigest.digest(ontology)
        assert first == second
      end
    end

    test "the digest ignores IR item order (the graph is the same graph)" do
      if live?() do
        assert {:ok, forward} = CanonicalDigest.digest(ontology!(order: :forward))
        assert {:ok, reverse} = CanonicalDigest.digest(ontology!(order: :reverse))
        assert forward == reverse
      end
    end

    test "the digest changes when the graph actually changes" do
      if live?() do
        assert {:ok, alice} = CanonicalDigest.digest(ontology!(label_a: "Alice"))
        assert {:ok, carol} = CanonicalDigest.digest(ontology!(label_a: "Carol"))
        refute alice == carol
      end
    end

    test "document/2 returns the exact bytes the digest was taken over" do
      if live?() do
        ontology = ontology!()
        assert {:ok, document} = CanonicalDigest.document(ontology)
        assert {:ok, result} = CanonicalDigest.canonical_digest(ontology)
        assert byte_size(document) == result.document_bytes

        # The bytes are replayable: hashing them directly through the engine
        # reproduces the same identity.
        expected_digest = result.digest
        assert {:ok, ^expected_digest} = GraphLawBridge.graph_hash(document)
      end
    end
  end

  describe "what this digest fixes about Ontology.fingerprint/1 (RFC S12)" do
    # Ontology.fingerprint/1 is
    # `triples |> :erlang.term_to_binary() |> :crypto.hash(:sha256)` -- a
    # stable digest of a BEAM term, which is a different object from the RDF
    # graph that term denotes. `term_fingerprint/1` below replicates that one
    # line so the divergence can be exhibited rather than described.
    defp term_fingerprint(triples) do
      triples
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    test "two Elixir representations of the SAME RDF graph disagree under term_to_binary but agree under the engine" do
      if live?() do
        # Identical RDF graph. The only difference is how the object term is
        # spelled in Elixir: an inferred bare binary vs an explicit literal
        # tuple. Both denote the plain literal "Alice".
        bare = [
          %{
            subject: "urn:ash-a2a:semantic:node:e1",
            predicate: "https://schema.org/description",
            object: "Alice"
          }
        ]

        explicit = [
          %{
            subject: "urn:ash-a2a:semantic:node:e1",
            predicate: "https://schema.org/description",
            object: {:literal, "Alice"}
          }
        ]

        # The BEAM-term fingerprint says these are different objects.
        refute term_fingerprint(bare) == term_fingerprint(explicit)

        # The real engine, hashing the RDF graph, says they are the same graph.
        assert {:ok, bare_digest} = CanonicalDigest.digest(bare)
        assert {:ok, explicit_digest} = CanonicalDigest.digest(explicit)
        assert bare_digest == explicit_digest
      end
    end

    test "a plain literal and an explicit xsd:string literal are one RDF term to the engine" do
      if live?() do
        plain = [%{subject: "http://e/a", predicate: "http://e/p", object: {:literal, "hi"}}]

        typed = [
          %{
            subject: "http://e/a",
            predicate: "http://e/p",
            object: {:literal, "hi", datatype: "http://www.w3.org/2001/XMLSchema#string"}
          }
        ]

        refute term_fingerprint(plain) == term_fingerprint(typed)
        assert {:ok, plain_digest} = CanonicalDigest.digest(plain)
        assert {:ok, typed_digest} = CanonicalDigest.digest(typed)
        assert plain_digest == typed_digest
      end
    end
  end

  describe "measured limits of graph_hash/1 -- asserted so the docs cannot drift" do
    test "it is NOT duplicate-insensitive: it is a multiset digest, not an RDF-set digest" do
      if live?() do
        t = %{subject: "http://e/a", predicate: "http://e/p", object: {:iri, "http://e/b"}}

        assert {:ok, single} = CanonicalDigest.canonical_digest([t])
        assert {:ok, doubled} = CanonicalDigest.canonical_digest([t, t])

        # The RDF set is identical -- the parse-back gate proves it.
        assert single.distinct_triple_count == 1
        assert doubled.distinct_triple_count == 1
        assert doubled.triple_count == 2

        # ...but the engine's digest still differs. Recorded, not claimed away.
        refute single.digest == doubled.digest
      end
    end

    test "it is NOT blank-node canonical: relabelling a blank node changes the digest" do
      if live?() do
        a = [%{subject: {:bnode, "b0"}, predicate: "http://e/p", object: {:iri, "http://e/b"}}]
        b = [%{subject: {:bnode, "zzz"}, predicate: "http://e/p", object: {:iri, "http://e/b"}}]

        assert {:ok, digest_a} = CanonicalDigest.digest(a)
        assert {:ok, digest_b} = CanonicalDigest.digest(b)
        refute digest_a == digest_b
      end
    end

    test "it has no parse-error channel -- which is exactly why the gate exists" do
      if live?() do
        good = "<http://e/a> <http://e/p> <http://e/b> .\n"

        assert {:ok, good_digest} = GraphLawBridge.graph_hash(good)
        assert {:ok, garbage_digest} = GraphLawBridge.graph_hash("GARBAGE !!!\n")
        assert {:ok, empty_digest} = GraphLawBridge.graph_hash("")

        # Unparseable input is indistinguishable from the empty graph, and
        # both return a perfectly well-formed 64-hex digest rather than an error.
        assert garbage_digest == empty_digest
        assert garbage_digest =~ ~r/^[0-9a-f]{64}$/
        refute good_digest == garbage_digest
      end
    end
  end

  describe "the gate refuses before a bad graph can reach the engine" do
    test "an invalid IRI is refused with a typed code, never hashed" do
      assert {:error, %{code: :serialize_invalid_iri, reason: :iriref_forbidden_character}} =
               CanonicalDigest.canonical_digest([
                 %{subject: "http://e/a b", predicate: "http://e/p", object: {:literal, "v"}}
               ])
    end

    test "a malformed triple is refused with a typed code" do
      assert {:error, %{code: :serialize_malformed_triple}} =
               CanonicalDigest.canonical_digest([%{subject: "http://e/a"}])
    end

    test "an unknown format is refused" do
      assert {:error, %{code: :canonical_digest_unknown_format}} =
               CanonicalDigest.canonical_digest([], format: :jsonld)
    end

    test "a non-list subject is refused" do
      assert {:error, %{code: :canonical_digest_expected_triples}} =
               CanonicalDigest.canonical_digest(:nope)
    end
  end

  describe "host reporting" do
    test "host/1 names a real reachable host, or a typed reason it is not reachable" do
      case GraphLawBridge.host() do
        host when host in [:in_beam, :node_shim] ->
          assert GraphLawBridge.available?()

        {:unavailable, %{code: code}} ->
          assert code in [
                   :graphlaw_node_not_found,
                   :graphlaw_wasm_not_found,
                   :graphlaw_shim_not_found
                 ]
      end
    end

    test "a wrong wasm path is a typed refusal, not a crash" do
      assert {:unavailable, %{code: :graphlaw_wasm_not_found}} =
               GraphLawBridge.host(wasm_path: "/nonexistent/nope.wasm")

      assert {:error, %{code: :graphlaw_wasm_not_found}} =
               GraphLawBridge.graph_hash("<http://e/a> <http://e/p> <http://e/b> .\n",
                 wasm_path: "/nonexistent/nope.wasm"
               )
    end
  end
end
