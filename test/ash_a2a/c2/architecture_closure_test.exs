defmodule AshA2A.C2.ArchitectureClosureTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.ArchitectureClosure

  test "protected control plane owns neither signer nor effector" do
    refute ArchitectureClosure.control_plane_signing_authority?()
    refute ArchitectureClosure.in_beam_protected_effector?()

    assert ArchitectureClosure.protected_pipeline() == [
             AshA2A.C2.PreparedEffect,
             AshA2A.C2.AuthorityClient,
             AshA2A.C2.ActuatorClient
           ]
  end
end
