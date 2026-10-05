# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.CS2.FleetContract do
  @moduledoc """
  Canonical RFC-CS2-001 fleet envelope (`cs2.fleet-contract.v1`, work
  CS2-WRK-012). Authority ceiling is CONSTRUCT: packets carry evidence, never
  authority to actuate.
  """

  @subject "RFC-CS2-001"
  @work_id "CS2-WRK-012"
  @spec subject() :: String.t()
  def subject, do: @subject

  @spec work_id() :: String.t()
  def work_id, do: @work_id

  @spec wrap(term()) :: map()
  def wrap(payload),
    do: %{
      schema: "cs2.fleet-contract.v1",
      subject: @subject,
      work_id: @work_id,
      authority_ceiling: :construct,
      payload: payload
    }
end
