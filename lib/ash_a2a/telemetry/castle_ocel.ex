# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.CastleOcel do
  @moduledoc """
  Pure projection of ash_a2a's admission/refusal outcomes into the evidence
  cluster's closed CASTLE OCEL vocabulary -- the same closed event vocabulary
  `BeamPM.CastleOcel` defines (`evidence_admitted`, `refused_observation`,
  `ggen_sync_observed`, ...) and the same converter shape
  `beam4pm/qualification/strata_pack_ocel.py` already uses for ggen
  qualification verdicts, applied here to ash_a2a's admission surface
  (`AshA2A.Semantic.Admission`, `AshA2A.Semantic.Refusal`).

  ## Observation, never subject success

    * `project/1` and `standing_to_event/1` are total, pure functions over
      their input. They mutate nothing, spawn nothing, read no clock, touch
      no filesystem, emit no messages, and attach no telemetry handlers --
      this is the emission seam (the event maps), not a live pipeline.
    * every projected event carries the fixed attributes
      `"authority" => "none"` / `"provenance" => "observation_only"`: no
      event in this log is, carries, or implies execution authority. An
      event named `evidence_admitted` records that an admission was
      OBSERVED, not that the admitted evidence is true.
    * timestamps are caller-supplied, never sampled.

  ## Standing -> event mapping (total over the S42 class domain)

  The S42 taxonomy classes (`AshA2A.Semantic.Refusal.classes/0`) plus the
  admitted outcome:

  | standing class           | CastleOcel event       | bound object type   |
  |--------------------------|------------------------|---------------------|
  | `:admitted`              | `evidence_admitted`    | `gym_act_episode`   |
  | 15 `:refused_*` classes  | `refused_observation`  | `system`            |
  | `:blocked_unknown`       | `ggen_sync_observed`   | `container`         |
  | `:blocked_resource`      | `ggen_sync_observed`   | `container`         |
  | `:unsupported_profile`   | `ggen_sync_observed`   | `container` |
  | anything else            | typed error            | --                  |

  The three non-admission classes are a **documented non-mapping** to
  `evidence_admitted`/`refused_observation`: `BLOCKED != REFUSED != ADMITTED`
  (S42), so they project as plain observations (`ggen_sync_observed`) with
  the class carried in `standing`, never as admissions and never as
  refusals. Any standing outside the domain refuses with
  `{:error, {:unknown_class, standing}}` -- never silently.

  ## Wire shape

  The repo's existing OCEL 2.0 envelope, the exact shape
  `strata_pack_ocel.py` emits and `BeamPM.Ocel.decode/1` decodes:
  `{"objectTypes", "eventTypes", "objects", "events"}` with
  `{event_id, event_type, event_time, attributes}` event maps. No second
  wire shape is introduced.

  ## Determinism

  Same input list -> structurally identical envelope: event ids are derived
  from list position and event name, object enumeration follows the
  canonical object-type order with lexicographic id sort, keys are sorted,
  and timestamps are caller-supplied.
  """

  @tool "ash_a2a admission"

  @typedoc "Caller-supplied projection input for one observed admission/refusal outcome."
  @type observation :: %{
          required(:standing) => atom(),
          required(:subject_id) => String.t(),
          required(:time) => String.t(),
          optional(:refusal_code) => String.t()
        }

  @admitted_classes [:admitted]
  @observation_classes [:blocked_unknown, :blocked_resource, :unsupported_profile]

  @doc """
  The standing classes this module admits as inputs: `:admitted`, the 18
  `AshA2A.Semantic.Refusal` classes. Everything else refuses.
  """
  @spec known_standings() :: [atom()]
  def known_standings, do: @admitted_classes ++ AshA2A.Semantic.Refusal.classes()

  @doc """
  The total standing -> CastleOcel event-name mapping, public for the
  totality court.

  `:admitted` -> `"evidence_admitted"`; every `AshA2A.Semantic.Refusal`
  refused class -> `"refused_observation"`; the two `BLOCKED_*` classes and
  `:unsupported_profile` -> `"ggen_sync_observed"` (documented non-mapping,
  see the moduledoc).
  """
  @spec standing_to_event(atom()) :: String.t() | nil
  def standing_to_event(:admitted), do: "evidence_admitted"
  # Documented non-mapping: BLOCKED_* / UNSUPPORTED_* are observations, not
  # refusals of the subject and not admissions.
  def standing_to_event(:blocked_unknown), do: "ggen_sync_observed"
  def standing_to_event(:blocked_resource), do: "ggen_sync_observed"
  def standing_to_event(:unsupported_profile), do: "ggen_sync_observed"

  def standing_to_event(standing) when is_atom(standing) do
    if standing in AshA2A.Semantic.Refusal.refused_classes() do
      "refused_observation"
    else
      nil
    end
  end

  def standing_to_event(_), do: nil

  @doc """
  Project an ordered list of observed admission/refusal outcomes into the
  OCEL 2.0 envelope (see the moduledoc). Pure and deterministic.

  Refusals (never silent):

    * `{:error, {:invalid_observation, element}}` -- not a map
    * `{:error, {:unknown_class, standing}}` -- standing outside the total
      mapping domain (the sabotage surface)
    * `{:error, {:missing_subject_id, standing}}` /
      `{:error, {:subject_id_not_binary, standing, v}}`
    * `{:error, {:missing_time, standing}}` / `{:error, {:time_not_binary, standing, v}}`
  """
  @spec project([observation()]) :: {:ok, map()} | {:error, term()}
  def project(observations) when is_list(observations) do
    Enum.reduce_while(observations, {:ok, {1, []}}, fn element, {:ok, {index, acc}} ->
      case build_event(element, index) do
        {:ok, event} -> {:cont, {:ok, {index + 1, [event | acc]}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {_, events}} -> {:ok, envelope(Enum.reverse(events))}
      error -> error
    end
  end

  @doc """
  Convenience for one observation: `{:ok, event_map}` or a typed error.
  `event_map` is the same map `project/1` puts in `"events"`.
  """
  @spec project_event(observation()) :: {:ok, map()} | {:error, term()}
  def project_event(observation), do: build_event(observation, 1)

  ## Event building (deterministic: index-derived ids)

  defp build_event(%{standing: standing} = element, index) do
    with {:ok, event_name} <- classify(standing),
         {:ok, subject_id} <- subject_id(standing, Map.get(element, :subject_id)),
         {:ok, time} <- time(standing, Map.get(element, :time)),
         refusal_code = normalise_refusal_code(event_name, Map.get(element, :refusal_code)) do
      attrs =
        %{
          "authority" => "none",
          "provenance" => "observation_only",
          "standing" => Atom.to_string(standing),
          "subject_id" => subject_id,
          "tool" => @tool
        }
        |> maybe_put_refusal_class(event_name, standing, refusal_code)

      {:ok,
       %{
         "event_id" => "ash-a2a-#{pad(index)}-#{event_name}",
         "event_type" => event_name,
         "event_time" => time,
         "attributes" => attrs
       }}
    end
  end

  defp build_event(other, _index), do: {:error, {:invalid_observation, other}}

  defp classify(standing) do
    case standing_to_event(standing) do
      nil -> {:error, {:unknown_class, standing}}
      event_name -> {:ok, event_name}
    end
  end

  defp subject_id(_standing, subject_id) when is_binary(subject_id) and subject_id != "",
    do: {:ok, subject_id}

  defp subject_id(standing, nil), do: {:error, {:missing_subject_id, standing}}
  defp subject_id(standing, other), do: {:error, {:subject_id_not_binary, standing, other}}

  defp time(_standing, time) when is_binary(time) and time != "", do: {:ok, time}
  defp time(standing, nil), do: {:error, {:missing_time, standing}}
  defp time(standing, other), do: {:error, {:time_not_binary, standing, other}}

  defp normalise_refusal_code("refused_observation", code) when is_binary(code) and code != "",
    do: code

  defp normalise_refusal_code("refused_observation", nil), do: "REFUSED"

  defp normalise_refusal_code(_event_name, code) when is_binary(code) and code != "",
    do: code

  defp normalise_refusal_code(_event_name, _), do: nil

  defp maybe_put_refusal_class(attrs, "refused_observation", standing, refusal_code) do
    Map.put(attrs, "refusal_class", Atom.to_string(standing))
    |> Map.put("refusal_code", refusal_code)
  end

  defp maybe_put_refusal_class(attrs, "ggen_sync_observed", standing, refusal_code) do
    Map.put(attrs, "refusal_class", Atom.to_string(standing))
    |> Map.put("refusal_code", refusal_code)
  end

  defp maybe_put_refusal_class(attrs, _event_name, _standing, _refusal_code), do: attrs

  defp pad(index), do: String.pad_leading(Integer.to_string(index), 4, "0")

  ## Envelope (objectTypes / eventTypes / objects / events, sorted keys)

  defp envelope(events) do
    objects =
      events
      |> Enum.map(fn event ->
        {object_type, object_id} = object_binding(event)

        Map.new([{"object_id", object_id}, {"object_type", object_type}])
      end)
      |> Enum.uniq()
      |> Enum.sort_by(&{Map.fetch!(&1, "object_type"), Map.fetch!(&1, "object_id")})

    %{
      "objectTypes" =>
        events
        |> Enum.map(&object_binding(&1) |> elem(0))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&Map.new([{"name", &1}, {"attributes", []}])),
      "eventTypes" =>
        events
        |> Enum.map(&Map.fetch!(&1, "event_type"))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&Map.new([{"name", &1}, {"attributes", []}])),
      "objects" => objects,
      "events" => events
    }
  end

  # Per-event-type object binding, restricted to the event names this module
  # emits (the CastleOcel closed binding: evidence_admitted -> gym_act_episode,
  # refused_observation -> system, ggen_sync_observed -> container).
  defp object_binding(%{"event_type" => "evidence_admitted"} = event) do
    {"gym_act_episode", "subject:" <> event["attributes"]["subject_id"]}
  end

  defp object_binding(%{"event_type" => "refused_observation"}) do
    {"system", "ash-a2a-admission"}
  end

  defp object_binding(%{"event_type" => "ggen_sync_observed"} = event) do
    {"container", "ash-a2a-admission:" <> event["attributes"]["standing"]}
  end
end
