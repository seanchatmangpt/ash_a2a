# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Semantic.PolicyPhenotypeTransportFenceTest do
  @moduledoc """
  Merge court for the phenotype transport fence: `from_map/2` must refuse
  every authority-key disguise main's #45 fence refuses (homoglyph, leetspeak,
  split token, camelCase, invisible mark, non-string key), not only the
  branch's original seven exact words. Real PolicyPhenotype, no doubles.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.PolicyPhenotype

  defp transport_map do
    {:ok, phenotype} =
      PolicyPhenotype.new(
        capability_iri: "urn:sa2a:capability:Example.Search.read",
        policy_family: "planner:Astar",
        conditionable_axes: %{"exploration" => %{min: 0.0, max: 1.0}},
        condition: %{"exploration" => 0.25},
        reaction_norms: %{"exploration" => %{slope: 0.5}},
        evidence_refs: ["urn:evidence:paper"]
      )

    PolicyPhenotype.to_map(phenotype)
  end

  test "clean transport map still round-trips" do
    map = transport_map()
    assert {:ok, %PolicyPhenotype{}} = PolicyPhenotype.from_map(map)
  end

  for key <- [
        "grant",
        "execution_grant",
        "аuthority",
        "auth0rity",
        "gr4nt",
        "executionGrant",
        "gr_ant",
        "auth​ority",
        "leaseHolder",
        "sudo"
      ] do
    test "top-level disguised authority key #{inspect(key)} is refused" do
      map = Map.put(transport_map(), unquote(key), true)

      assert {:error, %{code: :phenotype_authority_smuggling, detail: unquote(key)}} =
               PolicyPhenotype.from_map(map)
    end
  end

  test "disguised authority key nested inside a reaction norm is refused" do
    map =
      put_in(transport_map(), ["reaction_norms", "exploration", "l3ase"], "forever")

    assert {:error, %{code: :phenotype_authority_smuggling, detail: "l3ase"}} =
             PolicyPhenotype.from_map(map)
  end

  test "forged authority_semantics is refused" do
    map = put_in(transport_map(), ["authority_semantics", "phenotype_has_authority"], true)

    assert {:error, %{code: :phenotype_authority_smuggling}} = PolicyPhenotype.from_map(map)
  end

  test "forged atom-keyed authority_semantics next to the canonical string key is refused" do
    map = Map.put(transport_map(), :authority_semantics, %{"phenotype_has_authority" => true})

    assert {:error, %{code: :phenotype_authority_smuggling, detail: {:authority_semantics, _}}} =
             PolicyPhenotype.from_map(map)
  end

  test "a field given as both string and atom key is refused, not silently shadowed" do
    map = Map.put(transport_map(), :capability_iri, "urn:sa2a:capability:Other.Thing.write")

    assert {:error,
            %{
              code: :invalid_policy_phenotype_transport,
              detail: {:duplicate_key, ["capability_iri"]}
            }} =
             PolicyPhenotype.from_map(map)
  end

  test "extra key inside a range is refused by main's closed shape after transport" do
    map = put_in(transport_map(), ["conditionable_axes", "exploration", "step"], 0.1)

    assert {:error, %{code: :invalid_condition_axis_range}} = PolicyPhenotype.from_map(map)
  end

  test "extra key inside a reaction norm is refused, not dropped" do
    map = put_in(transport_map(), ["reaction_norms", "exploration", "gain"], 2.0)

    assert {:error, %{code: :invalid_reaction_norm}} = PolicyPhenotype.from_map(map)
  end

  test "unknown top-level transport key is refused, not ignored" do
    map = Map.put(transport_map(), "notes", "benign")

    assert {:error, %{code: :invalid_policy_phenotype_transport, detail: {:unknown_key, "notes"}}} =
             PolicyPhenotype.from_map(map)
  end

  test "atom-keyed transport map is still admitted" do
    map =
      transport_map()
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    assert {:ok, %PolicyPhenotype{}} = PolicyPhenotype.from_map(map)
  end

  test "digest mismatch is refused" do
    assert {:error, %{code: :policy_phenotype_digest_mismatch}} =
             PolicyPhenotype.from_map(transport_map(), String.duplicate("0", 64))
  end
end
