defmodule AshA2A.ConsequenceKernel.W5.EffectClaimStore do
  @moduledoc false
  @callback put(GenServer.server(), struct()) :: :ok | {:error, term()}
  @callback fetch(GenServer.server(), binary()) :: {:ok, struct()} | :not_found | {:error, term()}
  @callback fetch_effect(GenServer.server(), binary()) ::
              {:ok, struct()} | :not_found | {:error, term()}
  @callback transition(GenServer.server(), binary(), atom(), atom()) :: :ok | {:error, term()}
  @callback append_receipt(GenServer.server(), binary(), map()) :: :ok | {:error, term()}
  @callback receipts(GenServer.server(), binary()) ::
              {:ok, [map()]} | :not_found | {:error, term()}
end
