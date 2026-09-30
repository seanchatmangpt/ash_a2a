defmodule AshA2A.Semantic.InterchangeContractTest do
  use ExUnit.Case, async: true
  alias AshA2A.Semantic.InterchangeContract
  @sha String.duplicate("a", 40)
  @digest "sha256:" <> String.duplicate("b", 64)
  defp attrs, do: %{source_repository: "example/runtime", source_revision: @sha,
    semantic_vocabulary: "https://example.test/interchange/v1", interface_digest: @digest,
    projection_rule: "rust-wasm-component", target_runtime: "beam/wasmex", artifact_digest: @digest}

  test "identity is deterministic and evidence only" do
    assert {:ok, a} = InterchangeContract.new(attrs())
    assert {:ok, b} = InterchangeContract.new(attrs())
    assert a.portable_identity == b.portable_identity
    assert {a.technical_standing, a.external_standing, a.runtime_authority} == {"CANDIDATE", "NONE", "NONE"}
    assert :ok = InterchangeContract.verify(a)
  end

  test "requires exact source subject" do
    assert {:error, {:semantic_interchange_exact_subject_required, :source_revision}} =
      InterchangeContract.new(%{attrs() | source_revision: "main"})
  end

  test "cannot manufacture authority" do
    assert {:error, {:semantic_interchange_authority_ceiling, :runtime_authority}} =
      InterchangeContract.new(Map.put(attrs(), :runtime_authority, "ALLOW"))
  end

  test "projects only to existing release candidate boundary" do
    assert {:ok, c} = InterchangeContract.new(attrs())
    cap = InterchangeContract.capability_candidate(c, "graphlaw", "26.9.30")
    assert cap.state == :candidate
    assert cap.subject_revision == @sha
    assert cap.digest == c.portable_identity
    assert cap.standing_binding == nil
  end
end
