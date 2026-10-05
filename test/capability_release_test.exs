# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CapabilityReleaseTest do
  use ExUnit.Case, async: true

  alias AshA2A.{CapabilityRelease, StandingBinding}

  defp digest(char), do: "sha256:" <> String.duplicate(char, 64)

  defp standing_binding(id) do
    fields = %{
      "schema" => "ash-a2a.standing-binding/v1",
      "capability_id" => id,
      "capability_digest" => digest("a"),
      "subject_revision" => String.duplicate("1", 40),
      "court" => "sa2a",
      "technical_standing" => "CONFORMANT",
      "required_standing" => "CONFORMANT",
      "receipt_digest" => digest("c"),
      "receipt_source" => "git:test:receipts/courts/sa2a",
      "external_standing" => "NONE",
      "runtime_authority" => "NONE"
    }

    identity =
      "sha256:" <>
        (:crypto.hash(:sha256, Jcs.encode(fields))
         |> Base.encode16(case: :lower))

    %StandingBinding{
      capability_id: id,
      capability_digest: digest("a"),
      subject_revision: String.duplicate("1", 40),
      court: "sa2a",
      technical_standing: "CONFORMANT",
      required_standing: "CONFORMANT",
      receipt_digest: digest("c"),
      receipt_source: "git:test:receipts/courts/sa2a",
      portable_identity: identity,
      external_standing: "NONE",
      runtime_authority: "NONE"
    }
  end

  defp released(id \\ "cap", version \\ "26.9.30") do
    candidate =
      CapabilityRelease.candidate(id, version, digest("a"),
        subject_revision: String.duplicate("1", 40)
      )

    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))
    binding = standing_binding(id)

    %{
      admitted
      | state: :released,
        release_digest: binding.portable_identity,
        standing_binding: binding
    }
  end

  test "digest-shaped caller input cannot release an admitted capability" do
    candidate = CapabilityRelease.candidate("cap", "1", digest("a"))
    {:ok, admitted} = CapabilityRelease.admit(candidate, digest("b"))

    assert {:error, {:standing_binding_required, _}} =
             CapabilityRelease.release(admitted, digest("c"))

    assert {:error, :capability_exact_subject_missing} =
             CapabilityRelease.release(admitted, standing: "CONFORMANT")
  end

  test "fabricated durable-looking standing cannot manufacture a frozen fleet" do
    assert {:error, :standing_receipt_source_invalid} =
             CapabilityRelease.freeze([released("forged-source")])
  end

  test "freeze refuses release mismatch, forged standing identity, and authority conflation" do
    cap = released("forged")

    release_mismatch = %{cap | release_digest: digest("e")}

    assert {:error, {:standing_release_digest_mismatch, "forged"}} =
             CapabilityRelease.freeze([release_mismatch])

    forged_identity = digest("f")
    forged = %{
      cap
      | release_digest: forged_identity,
        standing_binding: %{cap.standing_binding | portable_identity: forged_identity}
    }

    assert {:error, {:standing_binding_identity_mismatch, _, ^forged_identity}} =
             CapabilityRelease.freeze([forged])

    binding = standing_binding("authority")
    conflated_binding = %{binding | runtime_authority: "ALLOW"}

    payload = %{
      "schema" => "ash-a2a.standing-binding/v1",
      "capability_id" => conflated_binding.capability_id,
      "capability_digest" => conflated_binding.capability_digest,
      "subject_revision" => conflated_binding.subject_revision,
      "court" => conflated_binding.court,
      "technical_standing" => conflated_binding.technical_standing,
      "required_standing" => conflated_binding.required_standing,
      "receipt_digest" => conflated_binding.receipt_digest,
      "receipt_source" => conflated_binding.receipt_source,
      "external_standing" => conflated_binding.external_standing,
      "runtime_authority" => conflated_binding.runtime_authority
    }

    forged_identity =
      "sha256:" <>
        (:crypto.hash(:sha256, Jcs.encode(payload))
         |> Base.encode16(case: :lower))

    conflated_binding = %{conflated_binding | portable_identity: forged_identity}
    cap = %{released("authority") | standing_binding: conflated_binding, release_digest: forged_identity}

    assert {:error, :runtime_authority_conflated} = CapabilityRelease.freeze([cap])
  end

  test "portable closure identity is independent of input ordering" do
    a = released("a")
    b = released("b")

    first = CapabilityRelease.portable_digest([a, b])
    second = CapabilityRelease.portable_digest([b, a])

    assert first == second
    assert String.starts_with?(first, "sha256:")
  end

  test "strict mode without closure fails closed while legacy stays compatible" do
    assert {:error, :capability_release_closure_missing} =
             CapabilityRelease.guard("capability", capability_release_mode: :strict)

    assert :ok =
             CapabilityRelease.guard("capability", capability_release_mode: :legacy)
  end

  test "retired capability cannot freeze back into executable closure" do
    capability = released("cap")
    {:ok, retired} = CapabilityRelease.retire(capability, digest("d"))

    assert {:error, {:not_released, "cap", :retired}} =
             CapabilityRelease.freeze([retired])
  end

  test "duplicate capability id is refused before evidence replay" do
    assert {:error, {:duplicate_capability_id, "cap"}} =
             CapabilityRelease.freeze([
               released("cap", "1"),
               released("cap", "2")
             ])
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
end
