# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.KeyCustody do
  @moduledoc false
  @callback mac(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback verify(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def mac(provider, payload, opts \\ []), do: provider.mac(payload, opts)
  def verify(provider, payload, tag, opts \\ []), do: provider.verify(payload, tag, opts)
end
