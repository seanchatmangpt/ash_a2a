defmodule AshA2A.ConsequenceKernel.RefusalRegistry do
 @codes [:canonical_unencodable,:effect_instance_missing_field,:prepared_effect_digest_mismatch,:prepared_record_identity_mismatch,:effect_claim_missing,:effect_in_flight,:consequence_unclassified,:authority_unknown_decision,:replay_effect_divergence,:kernel_bypass,:standing_unknown_outcome,:standing_evidence_missing,:effector_contract_violation]
 def known?(c), do: c in @codes
 def codes, do: @codes
end
