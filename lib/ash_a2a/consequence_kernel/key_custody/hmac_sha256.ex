# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.KeyCustody.HmacSha256 do
  @behaviour AshA2A.ConsequenceKernel.KeyCustody
  def mac(payload, opts) when is_binary(payload) do
    with {:ok, key} <- fetch_key(opts) do
      {:ok,
       "hmac-sha256:" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, payload), case: :lower)}
    end
  end

  def verify(payload, tag, opts) do
    with {:ok, expected} <- mac(payload, opts),
         true <- Plug.Crypto.secure_compare(expected, tag),
         do: :ok,
         else: (_ -> {:error, :prepared_authentication_failed})
  end

  defp fetch_key(opts) do
    case Keyword.fetch(opts, :key) do
      {:ok, key} when is_binary(key) and byte_size(key) >= 32 -> {:ok, key}
      _ -> {:error, :prepared_key_unavailable}
    end
  end
end
