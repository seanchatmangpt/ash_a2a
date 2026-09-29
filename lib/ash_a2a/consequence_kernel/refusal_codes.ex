defmodule AshA2A.ConsequenceKernel.RefusalCodes do
  @moduledoc false
  @rows %{
    canonical_unencodable: :blocked_invalid,
    canonical_depth_exceeded: :blocked_invalid,
    canonical_float_forbidden: :blocked_invalid,
    canonical_type_forbidden: :blocked_invalid,
    canonical_key_type_forbidden: :blocked_invalid,
    canonical_key_collision: :blocked_invalid,
    canonical_schema_tag_required: :blocked_invalid,
    canonical_digest_mismatch: :blocked_invalid,
    effect_instance_missing_field: :blocked_invalid,
    prepared_effect_digest_mismatch: :blocked_integrity,
    prepared_record_identity_mismatch: :blocked_integrity,
    effect_claim_missing: :blocked_state,
    effect_in_flight: :blocked_state,
    consequence_unclassified: :blocked_policy,
    authority_unknown_decision: :blocked_authority,
    replay_effect_divergence: :blocked_integrity,
    kernel_bypass: :blocked_architecture,
    standing_unknown_outcome: :blocked_state,
    standing_evidence_missing: :blocked_evidence,
    effector_contract_violation: :blocked_architecture
  }
  def rows, do: @rows
  def codes, do: Map.keys(@rows)
  def known?(c), do: Map.has_key?(@rows, c)
  def classify(c), do: Map.fetch(@rows, c)
end
