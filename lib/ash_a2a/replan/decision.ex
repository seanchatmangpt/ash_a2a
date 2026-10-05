# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Decision do
  @enforce_keys [:kind, :subject, :reason]
  defstruct [:kind, :subject, :reason, :provider, authority: :none]
  def replan(subject, reason), do: %__MODULE__{kind: :replan, subject: subject, reason: reason}
  def stop(subject, reason), do: %__MODULE__{kind: :stop, subject: subject, reason: reason}
end
