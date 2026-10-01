defmodule AshA2A.Semantic.EquivalenceEvidenceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{EquivalenceEvidence, InterchangeContract}

  @sha String.duplicate("a", 40)
  @interface "sha256:" <> String.duplicate("b", 64)
  @artifact_a "sha256:" <> String.duplicate("c", 64)
  @artifact_b "sha256:" <> String.duplicate("d", 64)
  @observations "sha256:" <> String.duplicate("e", 64)
  @falsifiers "sha256:" <> String.duplicate("f", 64)
  @context "sha256:" <> String.duplicate("9", 64)

  defp projection(rule, runtime, artifact) do
    {:ok, contract} =
      InterchangeContract.new(%{
        source_repository: "example/runtime",
        source_revision: @sha,
        semantic_vocabulary: "https://example.test/interchange/v1",
        interface_digest: @interface,
        projection_rule: rule,
        target_runtime: runtime,
        artifact_digest: artifact
      })
    contract
  end

  defp evidence_attrs do
    %{court: "cross-runtime/v1", profile: "semantic-interchange/v1",
      context_digest: @context, observation_digest: @observations,
      falsifier_digest: @falsifiers}
  end

  test "equivalence preserves distinct projection identities and has no authority" do
    left = projection("rust-wasm-component", "beam/wasmex", @artifact_a)
    right = projection("elixir-native", "beam/otp", @artifact_b)
    assert left.portable_identity != right.portable_identity
    assert {:ok, evidence} = EquivalenceEvidence.new(left, right, evidence_attrs())
    assert :ok = EquivalenceEvidence.verify(evidence, left, right)
    assert {evidence.technical_standing, evidence.external_standing, evidence.runtime_authority} ==
             {"CANDIDATE", "NONE", "NONE"}
  end

  test "ABI mismatch refuses equivalence" do
    left = projection("rust-wasm-component", "beam/wasmex", @artifact_a)
    {:ok, right} = InterchangeContract.new(%{
      source_repository: "example/runtime", source_revision: @sha,
      semantic_vocabulary: left.semantic_vocabulary,
      interface_digest: "sha256:" <> String.duplicate("0", 64),
      projection_rule: "elixir-native", target_runtime: "beam/otp", artifact_digest: @artifact_b})
    assert {:error, :semantic_equivalence_contract_mismatch} =
             EquivalenceEvidence.new(left, right, evidence_attrs())
  end

  test "artifact mutation invalidates replayed evidence" do
    left = projection("rust-wasm-component", "beam/wasmex", @artifact_a)
    right = projection("elixir-native", "beam/otp", @artifact_b)
    assert {:ok, evidence} = EquivalenceEvidence.new(left, right, evidence_attrs())
    mutated = projection("elixir-native", "beam/otp", "sha256:" <> String.duplicate("1", 64))
    assert {:error, :semantic_equivalence_identity_mismatch} =
             EquivalenceEvidence.verify(evidence, left, mutated)
  end

  test "profile and context are part of evidence identity" do
    left = projection("rust-wasm-component", "beam/wasmex", @artifact_a)
    right = projection("elixir-native", "beam/otp", @artifact_b)
    assert {:ok, original} = EquivalenceEvidence.new(left, right, evidence_attrs())
    assert {:ok, profile_changed} =
      EquivalenceEvidence.new(left, right, Map.put(evidence_attrs(), :profile, "semantic-interchange/v2"))
    assert {:ok, context_changed} =
      EquivalenceEvidence.new(left, right, Map.put(evidence_attrs(), :context_digest,
        "sha256:" <> String.duplicate("8", 64)))
    refute original.portable_identity == profile_changed.portable_identity
    refute original.portable_identity == context_changed.portable_identity
  end

  test "equivalence cannot manufacture runtime authority" do
    left = projection("rust-wasm-component", "beam/wasmex", @artifact_a)
    right = projection("elixir-native", "beam/otp", @artifact_b)
    assert {:error, {:semantic_equivalence_authority_ceiling, :runtime_authority}} =
             EquivalenceEvidence.new(left, right, Map.put(evidence_attrs(), :runtime_authority, "ALLOW"))
  end
end
