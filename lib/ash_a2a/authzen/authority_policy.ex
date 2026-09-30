defmodule AshA2A.AuthZEN.AuthorityPolicy do
  alias AshA2A.AuthZEN.DecisionGate
  alias AshA2A.C2.AuthorityRequest

  def admit(%AuthorityRequest{} = request, ctx) do
    with evidence when not is_nil(evidence) <- Map.get(ctx, :authzen_evidence),
         expected when is_binary(expected) <- Map.get(ctx, :authzen_expected_pdp),
         true <- request.effect_digest == request.effect.digest,
         :ok <- DecisionGate.admit(evidence, request.effect, expected) do
      :ok
    else
      nil -> {:error, :missing_policy_evidence}
      false -> {:error, :effect_digest_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_policy_context}
    end
  end

  def issue(%AuthorityRequest{} = request, ctx) do
    case Map.get(ctx, :local_certificate_issuer) do
      issuer when is_atom(issuer) -> issuer.issue(request, ctx)
      _ -> {:error, :missing_local_certificate_issuer}
    end
  end
end
