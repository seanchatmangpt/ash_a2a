defmodule AshA2A.ConsequenceKernel.PreparedEffectStore do
  @moduledoc false
  @type server :: GenServer.server()

  @callback put(server(), map()) :: :ok | {:error, term()}
  @callback fetch(server(), binary()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback transition(server(), binary(), atom(), atom()) :: :ok | {:error, term()}
  @callback claim_request(server(), binary(), term()) :: :ok | {:error, term()}
  @callback claim_effect(server(), binary(), term()) :: :ok | {:error, term()}
end
