# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ArchitectureClosure do
  @moduledoc """
  Static ownership statement for the C2 control plane.

  Protected execution terminates in ActuatorClient, never the in-BEAM
  Actuator implementation. Authority issuance terminates in AuthorityClient.
  """

  @protected_pipeline [
    AshA2A.C2.PreparedEffect,
    AshA2A.C2.AuthorityClient,
    AshA2A.C2.ActuatorClient
  ]

  def protected_pipeline, do: @protected_pipeline
  def control_plane_signing_authority?, do: false
  def in_beam_protected_effector?, do: false
end
