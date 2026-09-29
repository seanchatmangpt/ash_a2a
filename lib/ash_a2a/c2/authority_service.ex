defmodule AshA2A.C2.AuthorityService do
  alias AshA2A.C2.{AuthorityRequest, AuthorityResponse}
  def authorize(policy, %AuthorityRequest{}=r, ctx) do
    with :ok <- preserve_principal(r),
         :ok <- current_epochs(r, ctx),
         :ok <- policy.admit(r, ctx),
         {:ok, cert} <- policy.issue(r, ctx) do
      {:ok, AuthorityResponse.admit(cert)}
    else {:error, reason} -> {:ok, AuthorityResponse.refuse(reason)} end
  end
  defp preserve_principal(%{effect: %{principal: p}, principal: p}), do: :ok
  defp preserve_principal(_), do: {:error, :principal_mismatch}
  defp current_epochs(r,c) do
    if r.policy_epoch==c.policy_epoch and r.revocation_epoch==c.revocation_epoch and r.generation==c.generation,
      do: :ok, else: {:error,:stale_fence}
  end
end
