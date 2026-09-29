defmodule AshA2A.ConsequenceKernel.KeyCustody do
  @moduledoc false
  @callback mac(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback verify(binary(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def mac(provider, payload, opts \\ []), do: provider.mac(payload, opts)
  def verify(provider, payload, tag, opts \\ []), do: provider.verify(payload, tag, opts)
end
