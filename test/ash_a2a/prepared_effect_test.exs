# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PreparedEffectTest do
  use ExUnit.Case, async: true

  defp evidence_ref do
    %{
      "schema" => "sa2a.semantic-evidence-envelope.v1",
      "contractVersion" => "v26.9.29",
      "subject" => "urn:subject:1",
      "sourceDigest" => "sha256:" <> String.duplicate("a", 64),
      "graphDigest" => "sha256:" <> String.duplicate("b", 64),
      "replayIdentity" => "replay:subject:1",
      "envelopeDigest" => "sha256:" <> String.duplicate("c", 64),
      "authority" => "NONE",
      "consequence" => "EVIDENCE_ONLY"
    }
  end

  test "prepared digest binds effect" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    assert {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    assert p.prepared_digest =~ "sha256:"
    assert p.semantic_evidence == nil
  end

  test "semantic evidence is bound into prepared identity without authority promotion" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    assert {:ok, plain} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)

    assert {:ok, evidenced} =
             AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change,
               semantic_evidence: evidence_ref()
             )

    refute plain.prepared_digest == evidenced.prepared_digest
    assert evidenced.semantic_evidence["authority"] == "NONE"
  end

  test "prepared effect refuses evidence authority smuggling" do
    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    evidence = Map.put(evidence_ref(), "authority", "DO")

    assert {:error, %{code: :refused_semantic_evidence, subject: :authority}} =
             AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change,
               semantic_evidence: evidence
             )
  end
end
