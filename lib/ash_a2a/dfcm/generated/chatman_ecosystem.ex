# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Generated from priv/ggen/ash_a2a/dfcm/ontology.ttl. NEVER HAND EDIT.
defmodule AshA2A.DfCM.Generated.ChatmanEcosystem do
  @moduledoc false
  @donor_id "chatman_ecosystem"
  def donor_id, do: @donor_id
  def contract, do: AshA2A.DfCM.FleetIntake.fetch!(@donor_id)
  def envelope, do: AshA2A.DfCM.FleetIntake.envelope(@donor_id)
  def project(payload \\ %{}), do: AshA2A.DfCM.FleetIntake.project(@donor_id, payload)
  def admit_projection(projection), do: AshA2A.DfCM.FleetIntake.admit_projection(@donor_id, projection)
end
