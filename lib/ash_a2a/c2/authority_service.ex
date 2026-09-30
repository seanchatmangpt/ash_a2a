defmodule AshA2A.C2.AuthorityService do
  @moduledoc """
  Policy/issuance logic for an authority release.

  This module is not invoked by the protected control-plane pipeline. Deploy it
  only in the independent authority trust domain with its key provider.
  """
  alias AshA2A.C2.{AuthorityRequest, AuthorityResponse}

  def authorize(policy, %AuthorityRequest{} = r, ctx) do
    with :ok <- preserve_principal(r),
         :ok <- current_epochs(r, ctx),
         :ok <- policy_evidence(r, ctx),
         :ok <- policy.admit(r, ctx),
         {:ok, cert} <- policy.issue(r, ctx) do
      {:ok, AuthorityResponse.admit(cert)}
    else
      {:error, reason} -> {:ok, AuthorityResponse.refuse(reason)}
    end
  end

  # Opt-in precondition (`policy_evidence_required: true`): an external PDP
  # allow is evidence only. It must bind this exact request and never replaces
  # `policy.admit/2` or certificate issuance.
  defp policy_evidence(r, ctx) do
    if Map.get(ctx, :policy_evidence_required, false) do
      case Map.get(ctx, :policy_evidence) do
        %AshA2A.C2.PolicyEvidence{decision: :allow} = e ->
          if AshA2A.C2.PolicyEvidence.binds?(e, r), do: :ok, else: {:error, :policy_evidence_mismatch}

        _ ->
          {:error, :policy_evidence_missing}
      end
    else
      :ok
    end
  end

  defp preserve_principal(%{effect: %{principal: p}, principal: p}), do: :ok
  defp preserve_principal(_), do: {:error, :principal_mismatch}

  defp current_epochs(r, c) do
    if r.policy_epoch == c.policy_epoch and r.revocation_epoch == c.revocation_epoch and
         r.generation == c.generation, do: :ok, else: {:error, :stale_fence}
  end
end
