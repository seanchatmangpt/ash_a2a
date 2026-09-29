defmodule AshA2A.C2.ActuationPipeline do
  alias AshA2A.C2.{AuthorityRequest, AuthorityClient, Actuator}

  def execute(effect, ctx, authority_client, store, effector) do
    request = AuthorityRequest.new(effect, ctx)

    with {:ok, %{decision: :admit, certificate: cert}} <-
           AuthorityClient.authorize(authority_client, request, ctx),
         {:ok, result} <- Actuator.execute(effect, cert, ctx, store, effector) do
      {:ok, result}
    else
      {:ok, %{decision: :refuse, reason: reason}} -> {:error, {:authority_refused, reason}}
      other -> other
    end
  end
end
