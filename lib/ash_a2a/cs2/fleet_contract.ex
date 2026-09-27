defmodule AshA2A.CS2.FleetContract do
  @subject "RFC-CS2-001"
  @work_id "CS2-WRK-012"
  def subject, do: @subject
  def work_id, do: @work_id
  def wrap(payload), do: %{schema: "cs2.fleet-contract.v1", subject: @subject, work_id: @work_id, authority_ceiling: :construct, payload: payload}
end
