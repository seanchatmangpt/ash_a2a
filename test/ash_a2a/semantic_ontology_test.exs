defmodule AshA2A.Semantic.OntologyTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Ontology, Vocabulary}

  defp base_ir(entities_order \\ :forward) do
    entity1 = %{
      "id" => "e1",
      "kind" => "entity",
      "type" => "schema:Person",
      "label" => "Alice",
      "source_quote" => "Alice knows Bob"
    }

    entity2 = %{
      "id" => "e2",
      "kind" => "entity",
      "type" => "schema:Person",
      "label" => "Bob",
      "source_quote" => "Alice knows Bob"
    }

    entities =
      case entities_order do
        :forward -> [entity1, entity2]
        :reverse -> [entity2, entity1]
      end

    relation_known = %{
      "id" => "r1",
      "kind" => "relation",
      "subject" => "e1",
      "predicate" => "schema:knows",
      "object" => "e2",
      "source_quote" => "Alice knows Bob"
    }

    relation_unknown = %{
      "id" => "r2",
      "kind" => "relation",
      "subject" => "e1",
      "predicate" => "schema:knows",
      "object" => "nowhere",
      "source_quote" => "Alice knows nobody"
    }

    goal = %{
      "id" => "g1",
      "kind" => "goal",
      "description" => "Introduce Alice to Bob",
      "source_quote" => "Alice knows Bob"
    }

    %IR{
      source_id: "src-1",
      standing: :admitted,
      authority: :none,
      entities: entities,
      relations: [relation_known, relation_unknown],
      events: [],
      goals: [goal],
      constraints: [],
      capabilities: [],
      authorities: [],
      observations: [],
      uncertainties: [],
      exclusions: [],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  test "from_ir/1 returns {:ok, %Ontology{}} for admitted, authority-none IR" do
    assert {:ok, %Ontology{} = ontology} = Ontology.from_ir(base_ir())
    assert ontology.source_id == "src-1"
    assert ontology.standing == :admitted
    assert ontology.authority == :none
    assert is_list(ontology.triples)
  end

  test "triples include rdf:type, schema:description, prov:wasDerivedFrom for entity e1" do
    {:ok, ontology} = Ontology.from_ir(base_ir())
    subject = "urn:ash-a2a:semantic:node:e1"

    assert %{subject: ^subject, predicate: predicate, object: object} =
             Enum.find(ontology.triples, fn t ->
               t.subject == subject and t.predicate == Vocabulary.expand("rdf:type") and
                 t.object == Vocabulary.local(:entities)
             end)

    assert predicate == Vocabulary.expand("rdf:type")
    assert object == Vocabulary.local(:entities)

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == subject and t.predicate == Vocabulary.expand("schema:description") and
               t.object == "Alice"
           end)

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == subject and t.predicate == Vocabulary.expand("prov:wasDerivedFrom") and
               t.object == "urn:ash-a2a:source:src-1"
           end)
  end

  test "entity with a 'type' field gets an extra rdf:type triple with the expanded type as object" do
    {:ok, ontology} = Ontology.from_ir(base_ir())
    subject = "urn:ash-a2a:semantic:node:e1"
    expanded_type = Vocabulary.expand("schema:Person")

    type_triples =
      Enum.filter(ontology.triples, fn t ->
        t.subject == subject and t.predicate == Vocabulary.expand("rdf:type")
      end)

    assert Enum.any?(type_triples, &(&1.object == Vocabulary.local(:entities)))
    assert Enum.any?(type_triples, &(&1.object == expanded_type))
  end

  test "relation object rewritten to a semantic node uri when it matches a known id" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == "urn:ash-a2a:semantic:node:e1" and
               t.predicate == Vocabulary.expand("schema:knows") and
               t.object == "urn:ash-a2a:semantic:node:e2"
           end)
  end

  test "relation object left as raw literal when it does not match a known id" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert Enum.any?(ontology.triples, fn t ->
             t.subject == "urn:ash-a2a:semantic:node:e1" and
               t.predicate == Vocabulary.expand("schema:knows") and
               t.object == "nowhere"
           end)

    refute Enum.any?(ontology.triples, fn t -> t.object == "urn:ash-a2a:semantic:node:nowhere" end)
  end

  test "fingerprint is a deterministic sha256-hex string" do
    {:ok, ontology} = Ontology.from_ir(base_ir())

    assert is_binary(ontology.fingerprint)
    assert String.length(ontology.fingerprint) == 64
    assert ontology.fingerprint =~ ~r/^[0-9a-f]{64}$/
  end

  test "fingerprint is identical regardless of entities list order, proving triples are sorted before hashing" do
    {:ok, forward_ontology} = Ontology.from_ir(base_ir(:forward))
    {:ok, reverse_ontology} = Ontology.from_ir(base_ir(:reverse))

    assert forward_ontology.fingerprint == reverse_ontology.fingerprint
    assert forward_ontology.triples == reverse_ontology.triples
  end

  test "from_ir/1 refuses IR with wrong standing" do
    ir = %{base_ir() | standing: :candidate}

    assert {:error, %{code: :ontology_requires_admitted_semantics}} = Ontology.from_ir(ir)
  end

  test "from_ir/1 refuses IR with wrong authority" do
    ir = %{base_ir() | authority: :invalid}

    assert {:error, %{code: :ontology_requires_admitted_semantics}} = Ontology.from_ir(ir)
  end
end
