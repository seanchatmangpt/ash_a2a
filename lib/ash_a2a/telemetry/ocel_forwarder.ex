defmodule AshA2A.Telemetry.OcelForwarder do
  @moduledoc """
  Real OCEL v2 egress for `AshA2A.Dispatcher`'s own, already-real
  `:telemetry.span([:ash_a2a, :dispatch], ...)` (dispatcher.ex:137-140) --
  every skill dispatch across every `AshA2A`-backed app (the FreedomGym
  Chicago-core/LLM scenarios, the rap-battle integration test, any real
  A2A traffic) already fires this span; this module is the only new piece
  needed to give that traffic real OCEL v2 visibility, not a new
  instrumentation point.

  Mirrors `Xaas.Telemetry.OcelForwarder`'s exact pattern (real HTTP POST,
  best-effort, never fatal to the caller) but targets beam4pm's own real,
  already-running ingest endpoint (`BeamPM.OcelIngest.Router`,
  `POST /ocel/events`, confirmed by reading `lib/beam4pm_ocel_ingest.ex`
  directly) instead of ex4pm's envelope-wrapped ingest -- beam4pm's
  contract is simpler: a bare `{"events": [...]}` (or single-object) POST,
  each event needing `event_id`/`event_type`/`event_time`/`attributes`,
  no `schema`/`producer`/`sequence` envelope, no separate validator call
  (the router's own generated `BeamPM.Types.OcelEvent.new/1` constructor
  IS the validation, applied server-side).

  ## Real OCEL v2 shape emitted per dispatch

  `event_type` is `"ash_a2a.dispatch.<resource_short_name>.<skill_name>"` --
  real, introspected via `Ash.Resource.Info.short_name/1` on the dispatch's
  `resource_or_domain` metadata when it resolves to a real Ash resource
  (falls back to `inspect/1` for a domain-only dispatch, since
  `Ash.Resource.Info.short_name/1` requires an actual resource module).
  `attributes` carries the real `skill_name`, `reply_type` (`:reply` /
  `:input_required` / `:stream` / `:error`), and (for the error path) the
  real `stage`/`error` from `AshA2A.Dispatcher`'s own `stop_meta/1` --
  refusals are forwarded as real OCEL evidence too, not silently dropped.

  ## Attach

      AshA2A.Telemetry.OcelForwarder.attach!()

  Reads `Application.get_env(:ash_a2a, :ocel_ingest_url)` (e.g.
  `"http://127.0.0.1:4210"`) at call time, per span -- `nil` (the default)
  means "don't forward", matching `Xaas.Telemetry.OcelForwarder`'s own
  same-shaped `nil`-means-disabled convention.
  """

  require Logger

  @handler_id {__MODULE__, :dispatch_stop}

  @doc """
  Attaches the real `:telemetry.attach/4` handler for
  `[:ash_a2a, :dispatch, :stop]`. Idempotent: re-attaching with the same
  handler id is a real, harmless `{:error, :already_exists}` from
  `:telemetry` itself, not raised here.
  """
  @spec attach!() :: :ok
  def attach! do
    case :telemetry.attach(
           @handler_id,
           [:ash_a2a, :dispatch, :stop],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the handler (mainly for test isolation)."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:ash_a2a, :dispatch, :stop], measurements, metadata, _config) do
    case ingest_url() do
      nil -> :ok
      url -> forward(url, measurements, metadata)
    end
  end

  defp ingest_url, do: Application.get_env(:ash_a2a, :ocel_ingest_url)

  defp forward(url, measurements, metadata) do
    event = build_event(measurements, metadata)

    Req.post(url <> "/ocel/events",
      json: %{"events" => [event]},
      receive_timeout: receive_timeout_ms()
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning(
          "AshA2A.Telemetry.OcelForwarder: ingest at #{url} returned non-2xx status #{status}: #{inspect(body)}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "AshA2A.Telemetry.OcelForwarder: failed to forward OCEL event to #{url}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "AshA2A.Telemetry.OcelForwarder: unexpected error building/forwarding OCEL event: #{inspect(error)}"
      )

      :ok
  end

  defp build_event(measurements, metadata) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => event_type(metadata),
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => attributes(measurements, metadata),
      "relationships" => relationships(metadata)
    }
  end

  # Real E2O relationship, present exactly when `AshA2A.Dispatcher` resolved
  # a real object identity for this dispatch (`dispatcher.ex`'s `object_id/2`
  # -- a persisted Ash record's own primary key, or, for a generic `:action`
  # skill with no data-layer record at all, a real `plan_name` argument
  # naming a specific stateful instance). `[]` (never a fabricated id) when
  # the dispatch had no real object to relate to (e.g. a pure stateless echo
  # skill like `:run_phase`). Field name matches beam4pm's real
  # `BeamPM.OcelIngest.Router` wire contract exactly (`lib/beam4pm_ocel_ingest.ex`
  # `decode_relationships/1`: `"qualifier"` / `"object_id"`, snake_case --
  # not `"objectId"`).
  defp relationships(%{object_id: object_id}) when is_binary(object_id) and object_id != "" do
    [%{"qualifier" => "acted_on", "object_id" => object_id}]
  end

  defp relationships(_metadata), do: []

  defp event_type(%{resource_or_domain: resource, skill_name: skill}) do
    short_name =
      if Ash.Resource.Info.resource?(resource) do
        Ash.Resource.Info.short_name(resource)
      else
        inspect(resource)
      end

    "ash_a2a.dispatch.#{short_name}.#{skill}"
  end

  defp attributes(measurements, metadata) do
    base = %{
      "skill_name" => to_string(Map.get(metadata, :skill_name)),
      "resource_or_domain" => inspect(Map.get(metadata, :resource_or_domain)),
      "reply_type" => metadata |> Map.get(:reply_type) |> to_string_or_nil(),
      "duration_native" => measurements |> Map.get(:duration) |> to_string_or_nil()
    }

    case Map.get(metadata, :stage) do
      nil ->
        base

      stage ->
        base
        |> Map.put("stage", to_string(stage))
        |> Map.put("error", inspect(Map.get(metadata, :error)))
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp receive_timeout_ms, do: Application.get_env(:ash_a2a, :ocel_ingest_timeout_ms, 2_000)
end
