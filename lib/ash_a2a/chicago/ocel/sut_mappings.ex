defmodule AshA2A.Chicago.Ocel.SutMappings do
  @moduledoc """
  Admitted OCEL mappings for the telemetry the ash_a2a SUT already emits at
  its own boundaries (RFC-SA2A-002 §17). Courts add mappings for any further
  events through `AshA2A.Chicago.Court.ocel_mappings/0`.

  Activity vocabulary (implementation-specific, versioned by this module's
  BEAM md5 in the mapping digest):

  | telemetry event                                   | activity                  |
  |---------------------------------------------------|---------------------------|
  | `[:ash_a2a, :command_bus, :target]`               | `brce.target`             |
  | `[:ash_a2a, :command_bus, :admission]`            | `brce.admission`          |
  | `[:ash_a2a, :command_bus, :kill_switch]`          | `brce.kill_switch`        |
  | `[:ash_a2a, :command_bus, :claim]`                | `brce.claim`              |
  | `[:ash_a2a, :command_bus, :prepare]`              | `brce.prepare`            |
  | `[:ash_a2a, :command_bus, :actuate, :start]`      | `brce.actuate.start`      |
  | `[:ash_a2a, :command_bus, :actuate, :stop]`       | `brce.actuate.stop`       |
  | `[:ash_a2a, :command_bus, :commit]`               | `brce.commit`             |
  | `[:ash_a2a, :dispatch, :start]`                   | `dispatch.start`          |
  | `[:ash_a2a, :dispatch, :stop]`                    | `dispatch.stop`           |
  | `[:ash_a2a, :dispatch, :exception]`               | `dispatch.exception`      |
  | `[:ash_a2a, :receipt, :committed]`                | `receipt.committed`       |
  | `[:ash_a2a, :receipt, :outboxed]`                 | `receipt.outboxed`        |
  | `[:ash_a2a, :semantic, :admission, :start]`       | `admission.start`         |
  | `[:ash_a2a, :semantic, :admission, :stage]`       | `admission.stage`         |
  | `[:ash_a2a, :semantic, :admission, :stop]`        | `admission.stop`          |
  | `[:ash_a2a, :router, :tier_selected]`             | `router.tier_selected`    |
  | `[:ash_a2a, :agent, :cancel]`                     | `agent.cancel`            |

  Object types: `command`, `capability`, `principal`, `execution`, `receipt`,
  `skill`, `resource`, `ash_record`, `task`, `a2a_context`, `admission_stage`.
  """

  alias AshA2A.Chicago.Ocel.Mapping

  @spec mappings() :: [Mapping.t()]
  def mappings do
    command_bus() ++ dispatch() ++ receipts() ++ admission() ++ misc()
  end

  defp command_bus do
    for {suffix, activity} <- [
          {[:target], "brce.target"},
          {[:admission], "brce.admission"},
          {[:kill_switch], "brce.kill_switch"},
          {[:claim], "brce.claim"},
          {[:prepare], "brce.prepare"},
          {[:actuate, :start], "brce.actuate.start"},
          {[:actuate, :stop], "brce.actuate.stop"},
          {[:commit], "brce.commit"}
        ] do
      Mapping.new!(
        event: [:ash_a2a, :command_bus | suffix],
        activity: activity,
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"capability", meta[:capability_id], "capability"},
            {"principal", meta[:principal_id], "principal"},
            {"execution", meta[:execution_id], "execution"},
            {"receipt", meta[:receipt_id], "receipt"}
          ]
        end,
        attributes: fn _m, meta ->
          Map.take(meta, [:outcome, :code, :consequence, :reason])
        end
      )
    end
  end

  defp dispatch do
    objects = fn _m, meta ->
      [
        {"skill", meta[:skill_name], "skill"},
        {"resource", meta[:resource_or_domain] && inspect(meta[:resource_or_domain]), "resource"},
        {"ash_record", meta[:object_id], "acted_on"}
      ]
    end

    attributes = fn _m, meta -> Map.take(meta, [:reply_type, :stage, :error, :kind, :reason]) end

    for {suffix, activity} <- [
          start: "dispatch.start",
          stop: "dispatch.stop",
          exception: "dispatch.exception"
        ] do
      Mapping.new!(
        event: [:ash_a2a, :dispatch, suffix],
        activity: activity,
        source: __MODULE__,
        objects: objects,
        attributes: attributes
      )
    end
  end

  defp receipts do
    objects = fn _m, meta ->
      receipt = meta[:receipt] || %{}

      [
        {"receipt", Map.get(receipt, :receipt_id), "receipt"},
        {"command", Map.get(receipt, :command_id), "command"},
        {"capability", Map.get(receipt, :capability_id), "capability"}
      ]
    end

    attributes = fn _m, meta ->
      receipt = meta[:receipt] || %{}

      %{
        status: Map.get(receipt, :status),
        consequence: Map.get(receipt, :consequence),
        standing: Map.get(receipt, :standing)
      }
    end

    for {suffix, activity} <- [committed: "receipt.committed", outboxed: "receipt.outboxed"] do
      Mapping.new!(
        event: [:ash_a2a, :receipt, suffix],
        activity: activity,
        source: __MODULE__,
        objects: objects,
        attributes: attributes
      )
    end
  end

  defp admission do
    for {suffix, activity} <- [
          start: "admission.start",
          stage: "admission.stage",
          stop: "admission.stop"
        ] do
      Mapping.new!(
        event: [:ash_a2a, :semantic, :admission, suffix],
        activity: activity,
        source: __MODULE__,
        objects: fn _m, meta -> [{"admission_stage", meta[:stage], "stage"}] end,
        attributes: fn _m, meta ->
          Map.take(meta, [:stage, :outcome, :standing, :code, :determinacy])
        end
      )
    end
  end

  defp misc do
    [
      Mapping.new!(
        event: [:ash_a2a, :router, :tier_selected],
        activity: "router.tier_selected",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"resource", meta[:resource_or_domain] && inspect(meta[:resource_or_domain]),
             "resource"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:tier]) end
      ),
      Mapping.new!(
        event: [:ash_a2a, :agent, :cancel],
        activity: "agent.cancel",
        source: __MODULE__,
        objects: fn _m, meta ->
          [{"task", meta[:task_id], "task"}, {"a2a_context", meta[:context_id], "context"}]
        end
      )
    ]
  end
end
