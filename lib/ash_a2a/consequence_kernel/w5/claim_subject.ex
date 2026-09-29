defmodule AshA2A.ConsequenceKernel.W5.ClaimSubject do
  def bind(
        %{prepared_digest: p, instance: %{subject_digest: s}},
        %{prepared_digest: p, subject_digest: s}
      ),
      do: :ok

  def bind(%{prepared_digest: _}, %{prepared_digest: _}),
    do: {:error, :effect_claim_exact_subject_mismatch}

  def bind(_, _), do: {:error, :effect_claim_subject_invalid}
end
