defmodule AshA2A.ConsequenceKernel.W5.ClaimFence do
  def admit(%{request_claim: r, effect_claim: e, prepared_digest: p, claimed_prepared_digest: p})
      when is_binary(r) and is_binary(e) and r != e, do: :ok

  def admit(%{prepared_digest: _, claimed_prepared_digest: _}),
    do: {:error, :prepared_digest_mismatch}

  def admit(_), do: {:error, :claim_fence_refused}
end
