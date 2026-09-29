defmodule AshA2A.ConsequenceKernel.W5.ReplayEvidence do
 def derive(%{effect_id: e,prepared_digest: p,claim_id: c}) when is_binary(e) and is_binary(p) and is_binary(c), do: %{effect_id: e,prepared_digest: p,claim_id: c,authority: :none}
 def derive(_), do: {:error,:insufficient_replay_evidence}
end
