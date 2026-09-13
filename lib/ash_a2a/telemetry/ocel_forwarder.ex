defmodule AshA2A.Telemetry.OcelForwarder do
  @moduledoc """
  Best-effort OCEL v2 egress for raw dispatch spans and committed AshA2A
  command receipts.

  Dispatch events preserve the existing low-level execution visibility.
  Receipt events add replay/identity/standing evidence from the canonical
  CommandBus without changing command behavior. Both are observational only.
  """

  require Logger

  @dispatch_handler_id {__MODULE__, :dispatch_stop}
  @receipt_handler_id {__MODULE__, :receipt_committed}

  @spec attach!() :: :ok
  def attach! do
    :ok = attach(@dispatch_handler_id, [:ash_a2a, :dispatch, :stop])
    :ok = attach(@receipt_handler_id, [:ash_a2a, :receipt, :committed])
    :ok
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    results = [
      :telemetry.detach(@dispatch_handler_id),
      :telemetry.detach(@receipt_handler_id)
    ]

    if :ok in results, do: :ok, else: {:error, :not_found}
  end

  @doc false
  def handle_event([:ash_a2a, :dispatch, :stop], measurements, metadata, _config) do
    case ingest_url() do
      nil -> :ok
      url -> post_event(url, build_dispatch_event(measurements, metadata))
    end
  end

  def handle_event(
        [:ash_a2a, :receipt, :committed],
        _measurements,
        %{receipt: %AshA2A.Receipt{} = receipt},
        _config
      ) do
    case ingest_url() do
      nil -> :ok
      url -> post_event(url, AshA2A.SemanticProjection.ocel_event(receipt))
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp attach(handler_id, event) do
    case :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp ingest_url, do: Application.get_env(:ash_a2a, :ocel_ingest_url)

  defp post_event(url, event) do
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
        "AshA2A.Telemetry.OcelForwarder: unexpected error forwarding OCEL event: #{inspect(error)}"
      )

      :ok
  end

  defp build_dispatch_event(measurements, metadata) do
    %{
      "event_id" => Ash.UUIDv7.generate(),
      "event_type" => event_type(metadata),
      "event_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => dispatch_attributes(measurements, metadata),
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

  defp dispatch_attributes(measurements, metadata) do
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
