defmodule AshA2A.ConsequenceKernel.PreparedEffectStore do
  @moduledoc false
  @callback put(binary(), map()) :: :ok | {:error, term()}
  @callback fetch(binary()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback transition(binary(), atom(), atom()) :: :ok | {:error, term()}
  @callback claim_request(binary(), term()) :: :ok | {:error, term()}
  @callback claim_effect(binary(), term()) :: :ok | {:error, term()}
end
