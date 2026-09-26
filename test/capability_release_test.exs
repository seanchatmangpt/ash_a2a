defmodule AshA2A.CapabilityReleaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.CapabilityRelease

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  defp released(id \\ "MyApp.Resource.create", version \\ "26.9.26") do
    candidate = CapabilityRelease.candidate(id, version, digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    {:ok, released} = CapabilityRelease.release(admitted, digest("c"))
    released
  end

  test "only candidate -> admitted -> released enters a closure" do
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
    assert first.portable_digest == second.portable_digest
    assert String.starts_with?(first.portable_digest, "sha256:")
    assert first.portable_digest == CapabilityRelease.portable_digest([b, a])
  end

  test "strict guard refuses anything outside frozen release closure" do
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

  test "retired capability cannot freeze back into executable closure" do
    released = released("cap")
    {:ok, retired} = CapabilityRelease.retire(released, digest("d"))

    assert {:error, {:not_released, "cap", :retired}} =
             CapabilityRelease.freeze([retired])
  end

  test "strict binding records exact released version and stable replay identity" do
    capability = released("cap", "26.9.26")
    assert {:ok, closure} = CapabilityRelease.freeze([capability])

    assert {:ok, binding} =
             CapabilityRelease.binding("cap", capability_release_closure: closure)

    assert binding.closure_digest == closure.digest
    assert binding.portable_closure_digest == closure.portable_digest
    assert binding.capability_id == "cap"
    assert binding.capability_version == "26.9.26"
    assert binding.capability_digest == capability.digest
    assert binding.admission_digest == capability.admission_digest
    assert binding.release_digest == capability.release_digest
    assert String.starts_with?(binding.binding_digest, "sha256:")

    assert {:ok, replay} =
             CapabilityRelease.binding("cap", capability_release_closure: closure)

    assert replay == binding
  end

  test "release attributes are receipt-safe evidence identity, never authority" do
    capability = released("cap")
    assert {:ok, closure} = CapabilityRelease.freeze([capability])

    assert {:ok, binding} =
             CapabilityRelease.binding("cap", capability_release_closure: closure)

    attrs = CapabilityRelease.attributes(binding)

    assert attrs.release_closure_digest == closure.digest
    assert attrs.release_portable_closure_digest == closure.portable_digest
    assert attrs.release_capability_id == "cap"
    assert attrs.release_capability_version == capability.version
    assert attrs.release_capability_digest == capability.digest
    assert attrs.release_admission_digest == capability.admission_digest
    assert attrs.release_evidence_digest == capability.release_digest
    assert attrs.release_binding_digest == binding.binding_digest
    refute Map.has_key?(attrs, :authority)
  end

  test "strict skill filtering makes advertised and executable closure identical" do
    assert {:ok, closure} =
             CapabilityRelease.freeze([released("released.a"), released("released.b")])

    skills = [
      %{id: "candidate", name: :candidate},
      %{id: "released.b", name: :b},
      %{id: "released.a", name: :a}
    ]

    assert {:ok, filtered} =
             CapabilityRelease.filter_skills(skills,
               capability_release_closure: closure
             )

    assert Enum.map(filtered, & &1.id) == ["released.b", "released.a"]

    assert Enum.all?(filtered, fn skill ->
             CapabilityRelease.guard(skill.id, capability_release_closure: closure) == :ok
           end)
  end

  test "legacy skill filtering preserves existing capability index" do
    skills = [%{id: "a"}, %{id: "b"}]

    assert {:ok, ^skills} =
             CapabilityRelease.filter_skills(skills,
               capability_release_mode: :legacy
             )
  end

  test "strict filtering without closure refuses instead of advertising candidates" do
    assert {:error, :capability_release_closure_missing} =
             CapabilityRelease.filter_skills([%{id: "candidate"}],
               capability_release_mode: :strict
             )
  end

  test "duplicate capability id cannot freeze even when versions differ" do
    assert {:error, {:duplicate_capability_id, "cap"}} =
             CapabilityRelease.freeze([
               released("cap", "1"),
               released("cap", "2")
             ])
  end

  test "released ids are stable lexical projection" do
    assert {:ok, closure} =
             CapabilityRelease.freeze([
               released("z"),
               released("a"),
               released("m")
             ])

    assert CapabilityRelease.released_ids(closure) == ["a", "m", "z"]
  end
end
