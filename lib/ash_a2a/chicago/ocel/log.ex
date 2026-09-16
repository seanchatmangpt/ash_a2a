defmodule AshA2A.Chicago.Ocel.Log do
  @moduledoc """
  Producer-side OCEL 2.0 log builder and JSON serializer (RFC-SA2A-002 §15).

  Emits the OCEL 2.0 JSON serialization: top-level `objectTypes`,
  `eventTypes`, `objects`, `events`; typed attribute declarations
  (`string | integer | float | boolean | time`); qualified event-to-object and
  object-to-object `relationships`.

  This module is the PRODUCER. Syntactic and semantic validation of the
  written artifact must be done by an independent consumer that does not reuse
  this module (§15-§16).
  """

  defstruct events: [], objects: %{}, object_order: []

  @type t :: %__MODULE__{
          events: [map()],
          objects: %{String.t() => map()},
          object_order: [String.t()]
        }

  @epoch "1970-01-01T00:00:00Z"

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds (or merges into) an object. `id` must be globally unique across types."
  @spec put_object(t(), String.t(), String.t(), map()) :: t()
  def put_object(%__MODULE__{} = log, type, id, attributes \\ %{}) do
    case Map.fetch(log.objects, id) do
      {:ok, existing} ->
        %{
          log
          | objects:
              Map.put(log.objects, id, %{
                existing
                | attributes: Map.merge(existing.attributes, attributes)
              })
        }

      :error ->
        object = %{type: type, attributes: attributes, relationships: []}
        %{log | objects: Map.put(log.objects, id, object), object_order: [id | log.object_order]}
    end
  end

  @doc "Adds a qualified object-to-object relationship (idempotent)."
  @spec relate_objects(t(), String.t(), String.t(), String.t()) :: t()
  def relate_objects(%__MODULE__{} = log, from_id, to_id, qualifier) do
    rel = %{object_id: to_id, qualifier: qualifier}

    case Map.fetch(log.objects, from_id) do
      {:ok, object} ->
        if rel in object.relationships do
          log
        else
          %{
            log
            | objects:
                Map.put(log.objects, from_id, %{
                  object
                  | relationships: object.relationships ++ [rel]
                })
          }
        end

      :error ->
        log
    end
  end

  @doc """
  Adds an event. `:relationships` is `[{object_id, qualifier}]`; every
  referenced object must already have been added (referential integrity is
  enforced at encode time).
  """
  @spec add_event(t(), map()) :: t()
  def add_event(%__MODULE__{} = log, %{id: _, type: _, time: _} = event) do
    event = Map.merge(%{attributes: %{}, relationships: []}, event)
    %{log | events: [event | log.events]}
  end

  @doc "OCEL 2.0 JSON map. Raises if an event references an unknown object."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = log) do
    events = Enum.reverse(log.events)
    object_ids = Enum.reverse(log.object_order)

    for event <- events,
        {object_id, _q} <- event.relationships,
        not Map.has_key?(log.objects, object_id) do
      raise ArgumentError, "OCEL event #{event.id} references unknown object #{object_id}"
    end

    event_attr_types = attribute_types(events, & &1.type, & &1.attributes)

    object_attr_types =
      attribute_types(
        Enum.map(object_ids, &Map.fetch!(log.objects, &1)),
        & &1.type,
        & &1.attributes
      )

    %{
      "objectTypes" => type_decls(object_attr_types, Enum.map(object_ids, &log.objects[&1].type)),
      "eventTypes" => type_decls(event_attr_types, Enum.map(events, & &1.type)),
      "objects" =>
        Enum.map(object_ids, fn id ->
          object = Map.fetch!(log.objects, id)
          types = Map.get(object_attr_types, object.type, %{})

          %{
            "id" => id,
            "type" => object.type,
            "attributes" =>
              object.attributes
              |> Enum.sort()
              |> Enum.map(fn {name, value} ->
                %{
                  "name" => name,
                  "time" => @epoch,
                  "value" => typed_value(value, Map.fetch!(types, name))
                }
              end),
            "relationships" =>
              Enum.map(
                object.relationships,
                &%{"objectId" => &1.object_id, "qualifier" => &1.qualifier}
              )
          }
        end),
      "events" =>
        Enum.map(events, fn event ->
          types = Map.get(event_attr_types, event.type, %{})

          %{
            "id" => event.id,
            "type" => event.type,
            "time" => iso_time(event.time),
            "attributes" =>
              event.attributes
              |> Enum.sort()
              |> Enum.map(fn {name, value} ->
                %{"name" => name, "value" => typed_value(value, Map.fetch!(types, name))}
              end),
            "relationships" =>
              Enum.map(event.relationships, fn {object_id, qualifier} ->
                %{"objectId" => object_id, "qualifier" => qualifier}
              end)
          }
        end)
    }
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = log), do: log |> to_json_map() |> JSON.encode!()

  @doc "ISO-8601 UTC with microseconds from a DateTime or microsecond epoch integer."
  @spec iso_time(DateTime.t() | integer()) :: String.t()
  def iso_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def iso_time(us) when is_integer(us),
    do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  # One declared type per (entity type, attribute name). Conflicting value
  # kinds widen to "string" so every value matches its declaration.
  defp attribute_types(entities, type_fun, attrs_fun) do
    Enum.reduce(entities, %{}, fn entity, acc ->
      Enum.reduce(attrs_fun.(entity), acc, fn {name, value}, acc2 ->
        kind = kind(value)

        Map.update(acc2, type_fun.(entity), %{name => kind}, fn by_name ->
          Map.update(by_name, name, kind, fn
            ^kind -> kind
            _other -> "string"
          end)
        end)
      end)
    end)
  end

  defp type_decls(attr_types, names) do
    names
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{
        "name" => name,
        "attributes" =>
          attr_types
          |> Map.get(name, %{})
          |> Enum.sort()
          |> Enum.map(fn {attr, type} -> %{"name" => attr, "type" => type} end)
      }
    end)
  end

  defp kind(v) when is_boolean(v), do: "boolean"
  defp kind(v) when is_integer(v), do: "integer"
  defp kind(v) when is_float(v), do: "float"
  defp kind(%DateTime{}), do: "time"
  defp kind(_), do: "string"

  defp typed_value(v, "string") when is_binary(v), do: v
  defp typed_value(%DateTime{} = v, "string"), do: DateTime.to_iso8601(v)
  defp typed_value(v, "string"), do: to_string(v)
  defp typed_value(%DateTime{} = v, "time"), do: DateTime.to_iso8601(v)
  defp typed_value(v, _type), do: v
end
