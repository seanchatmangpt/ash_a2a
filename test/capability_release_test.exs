defmodule AshA2A.CapabilityReleaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.CapabilityRelease

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  defp released(id \ "MyApp.Resource.create", version \ "26.9.26") do
    candidate = CapabilityRelease.candidate(id, version, digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    {:ok, released} = CapabilityRelease.release(admitted, digest("c"))
    released
  end

  test "only the candidate -> admitted -> released lifecycle enters a closure" do
    candidate = CapabilityRelease.candidate("cap", "1", digest("a"))

    assert {:error, {:invalid_release_transition, :candidate, :released}} =
             CapabilityRelease.release(candidate, digest("c"))

    assert {:error, {:not_released, "cap", :candidate}} =
             CapabilityRelease.freeze([candidate])

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    {:ok, released} = CapabilityRelease.release(admitted, digest("c"))
    assert {:ok, closure} = CapabilityRelease.freeze([released])
    assert {:ok, ^released} = CapabilityRelease.select(closure, "cap")
  end

  test "closure digest is independent of input ordering" do
    a = released("a")
    b = released("b")

    assert {:ok, first} = CapabilityRelease.freeze([a, b])
    assert {:ok, second} = CapabilityRelease.freeze([b, a])
    assert first.digest == second.digest
  end

  test "strict guard refuses anything outside the frozen release closure" do
    assert {:ok, closure} = CapabilityRelease.freeze([released("released")])

    assert :ok =
             CapabilityRelease.guard("released",
               capability_release_closure: closure
             )

    assert {:error, {:capability_not_released, "candidate", closure_digest}} =
             CapabilityRelease.guard("candidate",
               capability_release_closure: closure
             )

    assert closure_digest == closure.digest
  end

  test "strict mode without closure fails closed while legacy stays compatible" do
    assert {:error, :capability_release_closure_missing} =
             CapabilityRelease.guard("capability", capability_release_mode: :strict)

    assert :ok =
             CapabilityRelease.guard("capability", capability_release_mode: :legacy)
  end

  test "retired capability cannot be frozen back into executable closure" do
    released = released("cap")
    {:ok, retired} = CapabilityRelease.retire(released, digest("d"))

    assert {:error, {:not_released, "cap", :retired}} =
             CapabilityRelease.freeze([retired])
  end
end
