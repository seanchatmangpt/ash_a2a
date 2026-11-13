# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.TelemetryBridge.PPlanHazard do
  @moduledoc """
  Hazard-aware agent surface: translates an upstream p-plan hazard event
  into an annotation on the A2A task surface, so a dispatcher sees the
  hazard directly on the task it was dispatched against.

  ## Production wiring

  LIBRARY-ONLY: this module has no production caller in `lib/`. Hosts wire it
  by subscribing to `AshPPlan.Telemetry.Broadcaster` (test-only dependency of
  this app), converting each `:hazard_tripped` envelope to the contract map
  below, and calling `annotate/2` on the dispatched task. Only tests call it
  in this repository.

  ## Event contract

  `annotate/2` consumes a **contract map** (not a pid, not a wire format):

      %{
        topic: "twin.partner.hazard",
        type: :hazard_tripped,
        run_id: "run-123",
        name: :partner_a,
        z: 3.1,
        threshold: 2.5,
        median: 105.0,
        mad: 7.0
      }

  Required fields: `:z` (number). Optional: `:threshold` (default 2.5, the
  `lhr:hazardThreshold` default of the
  `latency-hazard-radar` pack), `:mad` (number), `:median`,
  `:name`, `:run_id`, `:topic`, `:type`.

  The field vocabulary mirrors the `latency-hazard-radar` pack ontology
  (`urn:latency-hazard-radar:`): `lhr:hazardThreshold` (default 2.5),
  `lhr:refusalAtom` (`:insufficient_dispersion` when MAD = 0),
  `lhr:medianMillis` / `lhr:madMillis` (robust median/MAD estimates), and
  `lhr:triagePrompt` (event text emitted on trip). The upstream producer is
  `AshPPlan.Telemetry.Broadcaster`: it broadcasts an envelope
  `%{topic:, type: :hazard_tripped, run_id:, seq:, data:, emitted_at:}` whose
  `data` is an `AshPPlan.Telemetry.Event.HazardTripped{run_id, hazard, detail,
  meta}` struct, where `hazard` carries the robust statistics (`z`,
  `threshold`, `median`, `mad`) in the pack vocabulary. Because `:ash_pplan`
  is a test-only dependency of this app, the bridge itself consumes the
  contract map only — tests convert the live envelope to the contract.

  ## Behaviour

  - `z > threshold` (strictly greater — the robust-hazard trip law shared by
    the upstream median/MAD estimator and the `lhr:hazardThreshold` policy):
    patches the task's metadata with
    `"hazard" => "hazard: z=<z>, threshold=<threshold>"` and returns
    `{:ok, task}`.
  - `z <= threshold`: returns `{:ok, task}` unchanged — no annotation.
  - `:mad` absent: the dispersion is unverified, but `:mad` is optional in the
    contract, so the trip law still applies (annotate on trip) and a typed
    debug-level log records the unverified dispersion. A non-number `:mad`
    is `{:refused, :invalid_event}`.
  - non-number `:z` or `:threshold` (including `nil`): `{:refused,
    :invalid_event}` — never a silent pass, never a raise.
  - `mad == 0` (or an explicit `:error => :insufficient_dispersion` field):
    a degenerate, zero-dispersion window. No annotation is produced; returns
    `{:refused, :insufficient_dispersion}` and logs a typed refusal —
    division-by-zero and silent passes are both banned by the pack law.
  """

  alias AshA2A.Protocol.Task

  require Logger

  @annotation_key "hazard"
  @default_threshold 2.5
  @refusal_atom :insufficient_dispersion

  @doc "Metadata key under which the hazard annotation is patched."
  @spec annotation_key :: String.t()
  def annotation_key, do: @annotation_key

  @doc "Default hazard threshold (mirrors `lhr:hazardThreshold` default 2.5)."
  @spec default_threshold :: float()
  def default_threshold, do: @default_threshold

  @doc """
  Translate a hazard event (contract map) into a metadata patch on `task`.

  Returns `{:ok, task}` (possibly with the hazard annotation merged into
  `task.metadata`) or `{:refused, :insufficient_dispersion}`.
  """
  @spec annotate(Task.t(), map()) ::
          {:ok, Task.t()} | {:refused, :insufficient_dispersion | :invalid_event}
  def annotate(%Task{} = task, event) when is_map(event) do
    threshold = Map.get(event, :threshold, @default_threshold)
    mad = Map.get(event, :mad)
    z = Map.get(event, :z)

    cond do
      not is_number(z) or not is_number(threshold) or not (is_nil(mad) or is_number(mad)) ->
        Logger.warning(
          "hazard bridge refused annotation: :invalid_event " <>
            "(z/threshold/mad must be numbers, run_id=#{inspect(Map.get(event, :run_id))})"
        )

        {:refused, :invalid_event}

      degenerate?(event, mad) ->
        Logger.warning(
          "hazard bridge refused annotation: #{inspect(@refusal_atom)} " <>
            "(MAD = 0 zero-dispersion window, run_id=#{inspect(Map.get(event, :run_id))})"
        )

        {:refused, @refusal_atom}

      trip?(z, threshold) ->
        if is_nil(mad),
          do:
            Logger.debug(
              "hazard bridge: :mad absent, dispersion unverified (run_id=#{inspect(Map.get(event, :run_id))})"
            )

        metadata = task.metadata || %{}

        {:ok,
         %{task | metadata: Map.put(metadata, @annotation_key, annotation(event, threshold))}}

      true ->
        {:ok, task}
    end
  end

  @doc """
  The annotation a dispatcher sees on the task for `z` crossing `threshold`.
  """
  @spec annotation(map(), number()) :: String.t()
  def annotation(event, threshold) do
    "hazard: z=#{format_number(Map.get(event, :z))}, threshold=#{format_number(threshold)}"
  end

  @doc """
  Trip law: strictly greater than threshold (never equal) — the
  `lhr:hazardThreshold` policy from the latency-hazard-radar pack.
  """
  @spec trip?(number(), number()) :: boolean()
  def trip?(z, threshold) when is_number(z) and is_number(threshold), do: z > threshold
  def trip?(_, _), do: false

  defp degenerate?(_event, mad) when mad == 0 or mad == 0.0, do: true
  defp degenerate?(event, _mad), do: Map.get(event, :error) == @refusal_atom

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: Float.to_string(n)
  defp format_number(other), do: inspect(other)
end
