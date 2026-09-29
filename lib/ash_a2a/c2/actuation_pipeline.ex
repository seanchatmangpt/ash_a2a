defmodule AshA2A.C2.ActuationPipeline do
  @moduledoc """
  C2 control-plane pipeline.

  The control plane constructs a powerless effect, asks an external authority
  for a certificate, then sends both to an independent actuator. It never
  invokes an in-BEAM effector on this protected path.
  """

  alias AshA2A.C2.{ActuatorClient, AuthorityClient, AuthorityRequest}

  def execute(
        effect,
        ctx,
        authority_client \\ AshA2A.C2.AuthorityClient.Remote,
        actuator_client \\ AshA2A.C2.ActuatorClient.Remote
      ) do
    request = AuthorityRequest.new(effect, ctx)

    with {:ok, %{decision: :admit, certificate: cert}} <-
           AuthorityClient.authorize(authority_client, request, ctx),
         {:ok, receipt} <- ActuatorClient.execute(actuator_client, effect, cert, ctx) do
      {:ok, receipt}
    else
      {:ok, %{decision: :refuse, reason: reason}} -> {:error, {:authority_refused, reason}}
      other -> other
    end
  end
end
