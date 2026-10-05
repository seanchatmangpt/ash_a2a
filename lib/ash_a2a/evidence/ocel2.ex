# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Evidence.Ocel2 do
  @moduledoc """
  IEEE OCEL v2 ndjson serialization for affidavit-sealed evidence (PRD
  v26.10.4 §4.6, FR-06.3).

  A receipt sealed by the real Affidavit WASM engine
  (`AshA2A.Evidence.Affidavit.assemble_receipt/1`, format `core/v1`:
  `{format_version, events, chain_hash}` with a BLAKE3 rolling chain over
  `{id, seq, event_type, objects, payload_commitment}`) is projected into an
  OCEL v2 ndjson stream of event lines and object lines that correlates the
  four FR-06.3 object types: `WorkOrder`, `Agent`, `EvidencePackage`,
  `Resource`.

  ## Line shapes

  An *event line* carries the same five keys the repo's existing OCEL
  egress (`AshA2A.Telemetry.OcelForwarder`) already emits:
  `event_id`, `event_type`, `event_time` (ISO 8601 UTC), `attributes`
  (string-keyed map), and `relationships` (a list of
  `{qualifier, object_id, object_type}`).

  An *object line* carries `object_id`, `object_type` and `attributes` (a
  list of `{name, time, value}` rows — the OCEL v2 object-attribute form,
  where every attribute value is a timed row, not a fixed field).

  ## Validation

  `validate/2` checks the stream structurally and returns the repo's typed
  refusal shape `{:error, %{code: atom, detail: String.t()}}` — never a
  crash — for:

    * a line that is neither a well-formed event line nor a well-formed
      object line (`:bad_field`, `:missing_field`);
    * an `event_time` that is not ISO 8601 (`:bad_field`);
    * a relationship that does not name a declared object in the same
      stream (`:undeclared_object`) — the correlation closure FR-06.3
      requires;
    * an object whose `object_type` is outside the configured object-type
      vocabulary (`:unknown_object_type`).

  The default vocabulary is exactly the FR-06.3 four.
  """

  @object_types ~w(WorkOrder Agent EvidencePackage Resource)

  @typedoc "Typed refusal, matching the shape used across AshA2A."
  @type refusal :: {:error, %{code: atom(), detail: String.t()}}

  @doc "The FR-06.3 correlated object-type vocabulary."
  @spec object_types() :: [String.t()]
  def object_types, do: @object_types

  @doc """
  Builds one OCEL v2 object line.

  `attributes` is a map or keyword of object attribute values; each becomes a
  timed row `{name, time, value}` stamped at `time` (default: now, UTC).
  """
  @spec object(String.t(), String.t(), map() | keyword(), DateTime.t()) :: map()
  def object(object_id, object_type, attributes \\ %{}, time \\ DateTime.utc_now())
      when is_binary(object_id) and is_binary(object_type) do
    %{
      "object_id" => object_id,
      "object_type" => object_type,
      "attributes" =>
        attributes
        |> Map.new(fn {name, value} ->
          {to_string(name), %{"name" => to_string(name), "time" => iso8601(time), "value" => value}}
        end)
        |> Map.values()
    }
  end

  @doc """
  Builds one OCEL v2 event line (the same five-key shape
  `AshA2A.Telemetry.OcelForwarder` emits).
  """
  @spec event(String.t(), String.t(), DateTime.t(), map(), [map()]) :: map()
  def event(event_id, event_type, event_time \\ DateTime.utc_now(), attributes \\ %{}, relationships \\ [])
      when is_binary(event_id) and is_binary(event_type) and is_map(attributes) and is_list(relationships) do
    %{
      "event_id" => event_id,
      "event_type" => event_type,
      "event_time" => iso8601(event_time),
      "attributes" => attributes,
      "relationships" => relationships
    }
  end

  @doc """
  Projects a sealed `core/v1` receipt into an OCEL v2 stream (a list of
  event lines and object lines) that correlates `object_types/0`.

  Each receipt event becomes one OCEL event line whose relationships name the
  receipt event's own objects (`"id:type[:qualifier]"` refs — the assemble
  op's own normal form); each distinct object becomes one OCEL object line.
  Attributes carried on the OCEL event line: `seq`, `payload_commitment` and
  the receipt's format version, so the stream carries everything needed to
  replay to the same receipt bytes.

  `opts`: `:time` — the OCEL `event_time`/attribute timestamps (the receipt
  itself carries no wall-clock stamps; supply a fixed `DateTime` to make the
  projection byte-reproducible).

  Refuses `{:error, %{code: :bad_field}}` if the argument is not a `core/v1`
  receipt shape.
  """
  @spec from_receipt(map(), keyword()) :: {:ok, [map()]} | refusal()
  def from_receipt(%{"format_version" => format_version, "events" => events} = receipt, opts \\ [])
      when is_binary(format_version) and is_list(events) do
    time = Keyword.get(opts, :time, DateTime.utc_now())

    {event_lines, object_refs} =
      Enum.map_reduce(events, [], fn event, acc ->
        refs = receipt_object_refs(Map.get(event, "objects", []))

        line = event(
          Map.get(event, "id"),
          Map.get(event, "event_type"),
          time,
          %{
            "seq" => Map.get(event, "seq"),
            "payload_commitment" => Map.get(event, "payload_commitment"),
            "format_version" => receipt["format_version"]
          },
          Enum.map(refs, fn {oid, otype, qualifier} ->
            %{"qualifier" => qualifier || "related", "object_id" => oid, "object_type" => otype}
          end)
        )

        {line, refs ++ acc}
      end)

    object_lines =
      object_refs
      |> Enum.map(fn {id, type, _qualifier} -> {id, type} end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn {id, type} -> object(id, type, %{"sealed" => true}, time) end)

    {:ok, Enum.sort_by(event_lines ++ object_lines, &line_sort_key/1)}
  end

  def from_receipt(_other, _opts),
    do: {:error, %{code: :bad_field, detail: "not a core/v1 receipt: missing format_version/events"}}

  # Receipt object refs arrive from the real engine as `%{"id" => ..., "obj_type" => ...}`
  # maps (the serialized `ObjectRef`); qualifiers are nullable.
  defp receipt_object_refs(objects) do
    objects
    |> List.wrap()
    |> Enum.map(fn
      %{"id" => id, "obj_type" => type, "qualifier" => qualifier} when is_binary(qualifier) ->
        {id, type, qualifier}

      %{"id" => id, "obj_type" => type} ->
        {id, type, nil}

      ref when is_binary(ref) ->
        case String.split(ref, ":", parts: 3) do
          [id, type] -> {id, type, nil}
          [id, type, qualifier] -> {id, type, qualifier}
          _ -> {inspect(ref), "Resource", nil}
        end

      ref ->
        {inspect(ref), "Resource", nil}
    end)
  end

  # A relationship target that is qualified differently per event still names
  # one object line, so qualifiers do not participate in object identity.
  @doc """
  Encodes a stream of OCEL v2 lines to ndjson (one compact JSON object per
  line, `\n`-terminated).

  Lines are sorted with events before objects, by id, so the same stream
  always encodes to the same bytes.
  """
  @spec encode_ndjson([map()]) :: {:ok, String.t()} | refusal()
  def encode_ndjson(lines) when is_list(lines) do
    lines
    |> Enum.sort_by(&line_sort_key/1)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.encode(line) do
        {:ok, encoded} -> {:cont, {:ok, [encoded, "\n" | acc]}}
        {:error, reason} -> {:halt, {:error, %{code: :bad_field, detail: "line does not JSON-encode: " <> inspect(reason)}}}
      end
    end)
    |> case do
      {:ok, iodata} ->
        case IO.iodata_to_binary(iodata) do
          "" -> {:ok, ""}
          ndjson -> {:ok, ndjson}
        end

      refusal ->
        refusal
    end
  end

  def encode_ndjson(_other), do: {:error, %{code: :bad_field, detail: "ndjson payload must be a list of lines"}}

  @doc "Line sort key: events before objects, then by id."
  defp line_sort_key(%{"event_id" => id}) when is_binary(id), do: {0, id}
  defp line_sort_key(%{"object_id" => id}) when is_binary(id), do: {1, id}
  defp line_sort_key(_other), do: {2, ""}

  @doc """
  Decodes ndjson (one JSON object per line) into a list of line maps.

  Blank lines are skipped. Every line must decode as a JSON object;
  anything else is a typed refusal, never a crash.
  """
  @spec decode_ndjson(binary()) :: {:ok, [map()]} | refusal()
  def decode_ndjson(ndjson) when is_binary(ndjson) do
    ndjson
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{} = line_map} -> {:cont, {:ok, [line_map | acc]}}
        {:ok, _other} -> {:halt, {:error, %{code: :bad_field, detail: "ndjson line is not a JSON object: " <> line}}}
        {:error, reason} -> {:halt, {:error, %{code: :bad_json, detail: "ndjson line does not parse: " <> inspect(reason)}}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      refusal -> refusal
    end
  end

  def decode_ndjson(_other), do: {:error, %{code: :bad_field, detail: "ndjson payload must be a binary"}}

  @doc """
  Validates a decoded OCEL v2 stream: every line is a well-formed event or
  object line, every relationship names a declared object, and every object
  type is inside the configured vocabulary (default: `object_types/0`).
  """
  @spec validate([map()], keyword()) :: :ok | refusal()
  def validate(lines, opts \\ []) when is_list(lines) do
    vocabulary = Keyword.get(opts, :object_types, @object_types)
    validate_lines(lines, vocabulary)
  end

  defp validate_lines(lines, vocabulary) do
    declared =
      lines
      |> Enum.filter(&match?(%{"object_id" => _}, &1))
      |> Map.new(fn o -> {o["object_id"], o["object_type"]} end)

    Enum.reduce_while(lines, :ok, fn
      %{"event_id" => _} = line, :ok ->
        case validate_event(line, declared, vocabulary) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end

      %{"object_id" => _} = line, :ok ->
        case validate_object(line, vocabulary) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end

      other, :ok ->
        {:halt,
         {:error,
          %{
            code: :missing_field,
            detail: "line is neither an OCEL event line nor an object line: " <> inspect(other, limit: 5)
          }}}
    end)
  end

  defp validate_event(line, declared, vocabulary) do
    with :ok <- string_field(line, "event_id"),
         :ok <- string_field(line, "event_type"),
         :ok <- time_field(line, "event_time"),
         :ok <- attributes_field(line),
         :ok <- relationships_field(line, declared, vocabulary) do
      :ok
    end
  end

  defp validate_object(line, vocabulary) do
    with :ok <- string_field(line, "object_id"),
         :ok <- object_type_field(line, vocabulary),
         :ok <- timed_attribute_rows_field(line) do
      :ok
    end
  end

  defp string_field(line, key) do
    case Map.get(line, key) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, %{code: :missing_field, detail: "#{key} must be a non-empty string, got #{inspect(value)}"}}
    end
  end

  defp object_type_field(line, vocabulary) do
    case Map.get(line, "object_type") do
      value when is_binary(value) and value != "" ->
        if value in vocabulary do
          :ok
        else
          {:error,
           %{code: :unknown_object_type, detail: "object_type #{inspect(value)} is outside the OCEL vocabulary #{inspect(vocabulary)}"}}
        end

      value ->
        {:error, %{code: :missing_field, detail: "object_type must be a non-empty string, got #{inspect(value)}"}}
    end
  end

  defp time_field(line, key) do
    case Map.get(line, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _dt, _offset} -> :ok
          {:error, reason} -> {:error, %{code: :bad_field, detail: "#{key} is not ISO 8601: #{inspect(reason)}"}}
        end

      value ->
        {:error, %{code: :bad_field, detail: "#{key} must be an ISO 8601 string, got #{inspect(value)}"}}
    end
  end

  defp attributes_field(line) do
    case Map.get(line, "attributes") do
      value when is_map(value) ->
        if Enum.all?(Map.keys(value), &is_binary/1) do
          :ok
        else
          {:error, %{code: :bad_field, detail: "attributes keys must be strings"}}
        end

      value ->
        {:error, %{code: :bad_field, detail: "attributes must be a string-keyed map, got #{inspect(value)}"}}
    end
  end

  defp relationships_field(line, declared, vocabulary) do
    case Map.get(line, "relationships") do
      relationships when is_list(relationships) ->
        Enum.reduce_while(relationships, :ok, fn
          relationship, :ok ->
            with %{"qualifier" => q, "object_id" => oid, "object_type" => otype} <- relationship,
                 true <- is_binary(q) and is_binary(oid) and otype in vocabulary,
                 true <- Map.has_key?(declared, oid) do
              {:cont, :ok}
            else
              _ ->
                {:halt,
                 {:error,
                  %{
                    code: relationship_refusal_code(relationship, declared, vocabulary),
                    detail:
                      "relationship is not a well-formed {qualifier, object_id, object_type} naming a " <>
                        "declared object of the stream: #{inspect(relationship)}"
                  }}}
            end

          other, :ok ->
            {:halt, {:error, %{code: :bad_field, detail: "relationship must be a map, got #{inspect(other)}"}}}
        end)

      value ->
        {:error, %{code: :bad_field, detail: "relationships must be a list, got #{inspect(value)}"}}
    end
  end

  # The typed code for a refused relationship, in precedence order: malformed
  # shape (:bad_field), object type outside the vocabulary
  # (:unknown_object_type), or a well-formed relationship naming an object the
  # stream never declares (:undeclared_object).
  defp relationship_refusal_code(relationship, declared, vocabulary) do
    case relationship do
      %{"object_id" => oid, "object_type" => otype} when is_binary(oid) and is_binary(otype) ->
        cond do
          otype not in vocabulary -> :unknown_object_type
          not Map.has_key?(declared, oid) -> :undeclared_object
          true -> :bad_field
        end

      _ ->
        :bad_field
    end
  end

  defp timed_attribute_rows_field(line) do
    case Map.get(line, "attributes") do
      rows when is_list(rows) ->
        if Enum.all?(rows, fn
             %{"name" => n, "time" => t, "value" => _v} -> is_binary(n)
             _ -> false
           end) and
             Enum.all?(rows, fn %{"time" => t} ->
               match?({:ok, _, _}, DateTime.from_iso8601(t))
             end) do
          :ok
        else
          {:error, %{code: :bad_field, detail: "object attributes must be {name, time, value} rows"}}
        end

      value ->
        {:error, %{code: :bad_field, detail: "object attributes must be a list of timed rows, got #{inspect(value)}"}}
    end
  end

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
