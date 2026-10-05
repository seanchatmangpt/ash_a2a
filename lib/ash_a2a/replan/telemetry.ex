# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.Telemetry do
  @prefix [:ash_a2a, :replan]
  def emit(event, measurements, metadata),
    do: :telemetry.execute(@prefix ++ [event], measurements, metadata)

  def prefix, do: @prefix
end
