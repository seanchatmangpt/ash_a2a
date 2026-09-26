defmodule AshA2A.Semantic.PolicyPhenotypeTransportTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype
  alias AshA2A.Semantic.Refusal

  defp phenotype do
    assert {:ok, phenotype} =
             PolicyPhenotype.new(
               capability_iri: "urn:sa2a:capability:Example.Search.read",
               policy_family: "planner:Astar",
               conditionable_axes: %{
                 "exploration" => %{min: 0.0, max: 1.0},
                 "initiative" => %{min: 0.0, max: 1.0}
               },
               condition: %{
                 "exploration" => 0.25,
                 "initiative" => 0.75
               },
               reaction_norms: %{
                 "exploration" => %{slope: 0.5, reference_cue: 0.0}
               },
               evidence_refs: ["urn:evidence:paper"]
             )

    phenotype
  end

  test "canonical map round-trips with exact digest" do
    source = phenotype()
    map = PolicyPhenotype.to_map(source)
    digest = PolicyPhenotype.digest(source)

    assert {:ok, decoded} = PolicyPhenotype.from_map(map, digest)
    assert decoded == source
    assert PolicyPhenotype.digest(decoded) == digest
    assert map["authority_semantics"] == %{
             "candidate_only" => true,
             "phenotype_has_authority" => false,
             "execution_authority" => "external_command_bus_brce"
           }
  end

  test "map encoding is deterministic independent of source map insertion order" do
    source = phenotype()
    first = PolicyPhenotype.to_map(source)

    reordered =
      first
      |> Enum.reverse()
      |> Map.new()

    assert {:ok, decoded} = PolicyPhenotype.from_map(reordered)
    assert PolicyPhenotype.digest(decoded) == PolicyPhenotype.digest(source)
  end

  test "tampered expected digest is a typed identity refusal" do
    source = phenotype()

    assert {:error, %{code: :policy_phenotype_digest_mismatch}} =
             PolicyPhenotype.from_map(PolicyPhenotype.to_map(source), "sha256:tampered")

    assert Refusal.classify(:policy_phenotype_digest_mismatch) == :refused_identity
  end

  test "caller cannot add credential-shaped transport state" do
    source =
      phenotype()
      |> PolicyPhenotype.to_map()
      |> Map.put("credential", "secret")

    assert {:error, %{code: :phenotype_authority_smuggling, detail: "credential"}} =
             PolicyPhenotype.from_map(source)

    assert Refusal.classify(:phenotype_authority_smuggling) == :refused_authority
  end

  test "caller cannot mutate the fixed authority semantic declaration" do
    source =
      phenotype()
      |> PolicyPhenotype.to_map()
      |> put_in(["authority_semantics", "phenotype_has_authority"], true)

    assert {:error,
            %{
              code: :phenotype_authority_smuggling,
              detail: {:authority_semantics, _}
            }} = PolicyPhenotype.from_map(source)
  end

  test "transport parser accepts atom-keyed host maps without changing semantics" do
    source = phenotype()

    atom_map = %{
      capability_iri: source.capability_iri,
      policy_family: source.policy_family,
      conditionable_axes: source.conditionable_axes,
      condition: source.condition,
      reaction_norms: source.reaction_norms,
      evidence_refs: source.evidence_refs,
      authority_semantics: %{
        "candidate_only" => true,
        "phenotype_has_authority" => false,
        "execution_authority" => "external_command_bus_brce"
      }
    }

    assert {:ok, decoded} = PolicyPhenotype.from_map(atom_map)
    assert decoded == source
  end
end
