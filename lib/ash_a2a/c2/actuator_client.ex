defmodule AshA2A.C2.ActuatorClient do
  @moduledoc """
  Control-plane client for an independent actuator domain.

  Implementations may transport an exact PreparedEffect and certificate but
  receive no signing key, effector implementation, or protected credential.
  """

  @callback execute(AshA2A.C2.PreparedEffect.t(), AshA2A.C2.Certificate.t(), map()) ::
              {:ok, term()} | {:error, term()}

  def execute(client, effect, cert, ctx) when is_atom(client),
    do: client.execute(effect, cert, ctx)
end
