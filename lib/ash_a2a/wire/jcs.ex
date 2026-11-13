# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Wire.Jcs do
  @moduledoc """
  Thin wrapper over the `jcs` hex dependency (RFC 8785).

  Input MUST already be validated by `AshA2A.Identity.Canonical.Encodable`
  (string keys, no floats, bounded integers); this module performs no
  validation and no exception swallowing.
  """

  @doc "RFC 8785 canonical bytes of an already-normalized JSON term."
  @spec encode(term()) :: {:ok, binary()}
  def encode(normalized), do: {:ok, Jcs.encode(normalized)}
end
