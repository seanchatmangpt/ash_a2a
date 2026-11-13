# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Identity.Canonical do
  @moduledoc false
  alias AshA2A.Identity.Canonical.{Encodable, Normalizer}

  def normalize(value), do: Normalizer.normalize(value)

  @doc "Canonical JCS (RFC 8785) bytes of `value` after validation and normalization."
  @spec encode(term()) :: {:ok, binary()} | {:error, atom()}
  def encode(value) do
    with :ok <- Encodable.validate(value),
         {:ok, normalized} <- Normalizer.normalize(value) do
      with {:ok, bytes} <- AshA2A.Wire.Jcs.encode(normalized) do
        if byte_size(bytes) > Encodable.max_bytes(),
          do: {:error, :canonical_size_exceeded},
          else: {:ok, bytes}
      end
    end
  end

  def digest(value) do
    with {:ok, bytes} <- encode(value) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  end
end
