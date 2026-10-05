# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.IdentityVersion do
  @moduledoc false
  @version "sa2a.c1.identity.v1"
  def current, do: @version
  def admit(@version), do: :ok
  def admit(_), do: {:error, :canonical_schema_tag_required}
end
