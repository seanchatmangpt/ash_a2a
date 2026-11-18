# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DfCM.GeneratedDriftTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  @root Path.expand("../../..", __DIR__)

  test "generated module and court surfaces stay aligned with the manifest" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)

      module_path = Path.join([@root, "lib", "ash_a2a", "dfcm", "generated", id <> ".ex"])
      court_path = Path.join([@root, "priv", "dfcm", "fleet", "courts", id <> ".json"])

      assert File.exists?(module_path), "missing generated module for #{id}"
      assert File.exists?(court_path), "missing generated court for #{id}"

      module_text = File.read!(module_path)
      assert module_text =~ "Generated from priv/ggen/ash_a2a/dfcm/ontology.ttl"
      assert module_text =~ ~s(@donor_id "#{id}")

      court = court_path |> File.read!() |> Jason.decode!()
      assert court["subject"] == donor["subject"]
      assert court["falsifier"] == donor["falsifier"]
    end
  end

  test "canonical ontology remains the declared semantic owner" do
    manifest = FleetIntake.manifest()
    assert manifest["generated_from"] == "priv/ggen/ash_a2a/dfcm/ontology.ttl"

    ontology_path = Path.join([@root, "priv", "ggen", "ash_a2a", "dfcm", "ontology.ttl"])
    assert File.exists?(ontology_path)
    ontology = File.read!(ontology_path)

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert ontology =~ donor["repository"]
      assert ontology =~ donor["sha"]
      assert ontology =~ donor["falsifier"]
    end
  end
end
