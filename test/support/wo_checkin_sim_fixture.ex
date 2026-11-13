# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.WoCheckinSim.WoVisit do
  @moduledoc """
  V8-SIM-WORKER lane — one simulated worker agent proving the substrate
  end-to-end: an agent card advertising one skill `wo.check_in` (accepts
  workOrderId + visitId), backed by a handler that drives the srve woVisits
  machine law IN MEMORY, served over the real `AshA2A.Protocol.Plug` on a
  real ephemeral Bandit port.

  Machine law ported READ-ONLY from
  `/Users/sac/srve/servengine-frontend/src/machines/woVisits.machine.ts`
  (24-row table; the arms this sim exercises):

  - `visit_detail_ready` --LOG_CHECK_IN--> `check_in` (attendance write
    actor) --onDone--> `visit_detail_ready` (woVisits.machine.ts:389,
    438-451). The sim's terminal artifact: attendance recorded, machine back
    at `visit_detail_ready`.
  - `visit_detail_ready` --GEOFENCE_REFUSED--> `parked_override`
    (woVisits.machine.ts:404-406; backend contract 422 SP_NOT_AT_SITE).
  - `parked_override` --GEOFENCE_OVERRIDE with justification--> `check_in`;
    the unguarded fallback arm STAYS PARKED (fail-closed)
    (woVisits.machine.ts:479-487, guard woVisits.machine.ts:212-213).

  Visit-status vocabulary (en_route -> on_site -> work_in_progress) is the
  WO lifecycle mapping per
  `/Users/sac/srve/ontology/work-order-lifecycle.ttl` (SP en route 285-296,
  SP arrived 301-306, SP check-in completion 308-315). This handler keeps a
  per-visit in-memory record of the drive so assertions run on final state
  (Chicago).

  Consequence is declared `:observe` on the generic action — the run fn is
  pure in-memory transition tracking with no Ash/durable mutation, so no
  BRCE outbox anchor is owed (a durable mutation would need `:change` plus
  the receipt-outbox anchor, `AshA2A.BrceAnchor.admit/2`).
  """

  use Ash.Resource,
    domain: AshA2A.Test.WoCheckinSim.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  require Ash.Query

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :wo_check_in, :map do
      # camelCase argument atoms: the A2A wire keys (workOrderId, visitId,
      # ...) pass through unchanged (empty argument_mapping default), so the
      # wire vocabulary IS the machine payload vocabulary.
      argument(:workOrderId, :string, allow_nil?: false)
      argument(:visitId, :string, allow_nil?: false)
      argument(:geofenceRefused, :boolean, allow_nil?: true, default: false)
      argument(:distanceMeters, :integer, allow_nil?: true)
      argument(:overrideJustification, :string, allow_nil?: true)

      run(fn input, _context ->
        wo = input.arguments[:workOrderId]
        visit_id = input.arguments[:visitId]

        initial =
          AshA2A.Test.WoCheckinSim.MachineLaw.state(wo, visit_id) ||
            AshA2A.Test.WoCheckinSim.MachineLaw.init(wo, visit_id)

        event =
          cond do
            input.arguments[:geofenceRefused] == true ->
              {:geofence_refused, input.arguments[:distanceMeters]}

            is_binary(input.arguments[:overrideJustification]) ->
              {:geofence_override, input.arguments[:overrideJustification]}

            true ->
              :log_check_in
          end

        case AshA2A.Test.WoCheckinSim.MachineLaw.transition(initial, event) do
          {:ok, next, artifact} ->
            AshA2A.Test.WoCheckinSim.MachineLaw.commit(wo, visit_id, next)
            {:ok, artifact}

          :refused ->
            AshA2A.Test.WoCheckinSim.MachineLaw.commit(wo, visit_id, initial)

            {:ok,
             %{
               "state" => Atom.to_string(initial),
               "terminal" => false,
               "refusal" => "stays parked: override requires a justification (fail-closed)"
             }}
        end
      end)
    end
  end

  a2a do
    # hide the auto-exposed :read so the card advertises exactly ONE skill
    skill :read, :read, expose?: false

    skill :"wo.check_in", :wo_check_in do
      # In-memory transition tracking only; a durable write would be :change.
      consequence :observe
    end
  end
end

defmodule AshA2A.Test.WoCheckinSim.MachineLaw do
  @moduledoc """
  The ported woVisits transition table (read-only port; cite header on the
  resource above). States/events are the machine's own vocabulary.
  """

  use Agent

  @doc "visit starts at the machine's initial state."
  def init(wo, visit_id) do
    Agent.update(__MODULE__, &Map.put_new(&1, key(wo, visit_id), :visit_detail_ready))
    :visit_detail_ready
  end

  @doc """
  The machine law. Returns `{:ok, next_state, artifact}` or `:refused`
  (the unguarded fallback arm — fail-closed).
  """
  def transition(:visit_detail_ready, :log_check_in) do
    {:ok, :visit_detail_ready,
     %{
       "state" => "visit_detail_ready",
       "terminal" => true,
       "visited" => [
         "visit_detail_ready",
         "check_in",
         "visit_detail_ready"
       ],
       "attendanceRecorded" => true,
       "attendanceMode" => "internal-checkin"
     }}
  end

  def transition(:visit_detail_ready, {:geofence_refused, distance}) do
    {:ok, :parked_override,
     %{
       "state" => "parked_override",
       "terminal" => false,
       "visited" => ["visit_detail_ready", "parked_override"],
       "geofenceRefusal" => %{"distance" => distance}
     }}
  end

  # GEOFENCE_OVERRIDE with justification -> check_in -> onDone -> ready
  def transition(:parked_override, {:geofence_override, justification})
      when is_binary(justification) and justification != "" do
    {:ok, :visit_detail_ready,
     %{
       "state" => "visit_detail_ready",
       "terminal" => true,
       "visited" => [
         "visit_detail_ready",
         "parked_override",
         "check_in",
         "visit_detail_ready"
       ],
       "attendanceRecorded" => true,
       "overrideJustification" => justification
     }}
  end

  def transition(_other, _event), do: :refused

  def state(wo, visit_id), do: Agent.get(__MODULE__, &Map.get(&1, key(wo, visit_id)))

  def commit(wo, visit_id, next),
    do: Agent.update(__MODULE__, &Map.put(&1, key(wo, visit_id), next))

  def reset, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  defp key(wo, v), do: {wo, v}
end

defmodule AshA2A.Test.WoCheckinSim.Domain do
  @moduledoc """
  Fixture domain (same pattern as `AshA2A.Test.PlugFixture.Domain`,
  test/support/plug_agent_card_fixture.ex:35-48).
  """

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.WoCheckinSim.WoVisit)
  end
end

defmodule AshA2A.Test.WoCheckinSim.WorkerAgent do
  @moduledoc """
  The simulated worker agent. Card advertises exactly one skill
  (`wo.check_in`); dispatch runs the real `AshA2A.Dispatcher` path so the
  card can never advertise what dispatch can't serve.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.WoCheckinSim.WoVisit,
    name: "wo_checkin_sim_worker",
    require_authenticated_caller: false
end
