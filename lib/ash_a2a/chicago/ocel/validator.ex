defmodule AshA2A.Chicago.Ocel.Validator do
  @moduledoc """
  Independent OCEL 2.0 JSON-serialization validator (RFC-SA2A-002 §15, §16,
  §104, §106, Appendix G).

  Implemented from the OCEL 2.0 specification
  (<https://www.ocel-standard.org/2.0/ocel20_specification.pdf>) and its JSON
  serialization -- NOT from the producer. It never aliases, imports or calls
  `AshA2A.Chicago.Ocel.Log`, `AshA2A.Chicago.Observer`,
  `AshA2A.Chicago.Ocel.Mapping` or `AshA2A.Chicago.Query` (§15-§16: the court
  validates the produced OCEL independently of the producer; a guard test
  inspects this module's BEAM atoms to keep it that way).

  It reads the artifact from disk (§16: validation happens after the artifact
  is durably written, never over an in-memory structure) and content-addresses
  the exact bytes it judged.

  ## Checks (`validate_file/1`)

    * the bytes are JSON and the document is a JSON object
    * `objectTypes`, `eventTypes`, `objects`, `events` are present and arrays
    * every type declaration has a non-empty string `name` and an
      `attributes` array; type names are unique per kind
    * every attribute declaration has a unique non-empty `name` and a `type`
      in `string | integer | float | boolean | time`
    * object ids and event ids are non-empty strings, unique per kind
    * every object/event `type` is declared
    * every attribute used is declared on its type, carries a `value`
      conforming to the declared type, and object attributes carry a parseable
      `time`; an event attribute name appears at most once per event
    * every event `time` is a parseable ISO-8601 extended-format date-time
    * every event-to-object and object-to-object relationship `objectId`
      resolves to a declared object, and every `qualifier` is a string

  Attribute values are accepted either as the native JSON type of the declared
  attribute type (`integer` -> JSON integer, `float` -> JSON number, `boolean`
  -> JSON boolean, `string`/`time` -> JSON string) or as a JSON string in that
  type's lexical form (`"42"`, `"4.2"`, `"true"`), so both typed and
  all-string JSON serializations validate. Time values must parse as ISO-8601
  extended-format date-times (`2026-09-16T10:00:00.123Z`,
  `2026-09-16T12:00:00+02:00`); a date-time without a UTC offset is accepted with a
  `time_without_offset` warning (it cannot be ordered across hosts, §20).

  ## Evidence completeness (`supports?/2`, §106)

  A syntactically valid artifact can still be unable to support the
  predicates a profile requires. `supports?/2` validates the same bytes and
  then checks that at least one event exists for every required activity
  (optionally with required attribute values). Incomplete evidence is refused,
  never read as conformance: `Unknown(ValidExecution) ⇒ ¬Conformant`.

  ## Telemetry (the deciding boundary emits its own evidence, §12, §18)

    * `[:ash_a2a, :chicago, :ocel, :validated]` -- measurements
      `%{error_count, bytes, duration_us}`; metadata `%{outcome: :valid |
      :invalid, error_count, error_codes, artifact_sha256, serialization,
      validator, validator_version, path}`
    * `[:ash_a2a, :chicago, :ocel, :completeness]` -- measurements
      `%{missing_count, required_count, duration_us}`; metadata `%{outcome:
      :supported | :incomplete | :invalid, missing, missing_count,
      required_count, artifact_sha256, validator, validator_version, path}`
  """

  @name "AshA2A.Chicago.Ocel.Validator"
  @version "1.0.0"
  @specification "OCEL 2.0 (https://www.ocel-standard.org/2.0/ocel20_specification.pdf)"
  @serialization "json"
  @top_level ["objectTypes", "eventTypes", "objects", "events"]
  @attribute_types ["string", "integer", "float", "boolean", "time"]
  @max_errors 1_000

  @validated_event [:ash_a2a, :chicago, :ocel, :validated]
  @completeness_event [:ash_a2a, :chicago, :ocel, :completeness]

  @error_codes [
    "unreadable_artifact",
    "non_json",
    "not_an_object",
    "missing_top_level_key",
    "missing_required_field",
    "invalid_type",
    "empty_identifier",
    "duplicate_type_name",
    "invalid_attribute_type",
    "duplicate_attribute_declaration",
    "duplicate_object_id",
    "duplicate_event_id",
    "undeclared_object_type",
    "undeclared_event_type",
    "undeclared_attribute",
    "attribute_value_type_mismatch",
    "invalid_time",
    "dangling_object_reference",
    "invalid_qualifier",
    "duplicate_event_attribute"
  ]

  @type error :: %{String.t() => String.t()}
  @type report :: %{String.t() => term()}
  @type requirement :: String.t() | {String.t(), %{optional(String.t() | atom()) => term()}}

  @doc "Telemetry events this validator emits."
  @spec telemetry_events() :: [[atom()]]
  def telemetry_events, do: [@validated_event, @completeness_event]

  @doc "The OCEL 2.0 attribute types accepted in declarations."
  @spec attribute_types() :: [String.t()]
  def attribute_types, do: @attribute_types

  @doc "Every error code a report can carry."
  @spec error_codes() :: [String.t()]
  def error_codes, do: @error_codes

  @doc "Validator identity bound into every report (§16, §21)."
  @spec identity() :: %{String.t() => String.t()}
  def identity do
    %{
      "name" => @name,
      "version" => @version,
      "specification" => @specification,
      "beam_md5" => Base.encode16(__MODULE__.module_info(:md5), case: :lower)
    }
  end

  @doc """
  Validates the OCEL 2.0 JSON artifact at `path`.

  Returns `{:ok, report}` when the artifact is valid and `{:error, report}`
  otherwise. `report` is JSON-safe: `valid`, `serialization`, `validator`,
  `artifact_path`, `artifact_sha256`, `artifact_bytes`, `validated_at`,
  `counts`, `error_count`, `errors` (`[%{"path", "code", "message"}]`, first
  #{@max_errors}), `errors_truncated`, `warnings`.
  """
  @spec validate_file(Path.t()) :: {:ok, report()} | {:error, report()}
  def validate_file(path) do
    started = System.monotonic_time(:microsecond)
    {report, _doc} = inspect_file(path)
    emit_validated(report, path, started)
    if report["valid"], do: {:ok, report}, else: {:error, report}
  end

  @doc """
  Evidence-completeness check (§106): validates the artifact at `path` and
  confirms it contains at least one event of every required activity.

  `required` is a list of activity names or `{activity, %{attr => value}}`
  pairs (every listed attribute must be present on the same event with a
  value whose string form equals `value`).

  Returns `{:ok, report}` only when the artifact is valid and nothing is
  missing (`report["missing"] == []`); otherwise `{:error, report}` with
  `outcome` `"incomplete"` or `"invalid"`. An invalid artifact supports
  nothing: every requirement is reported missing.
  """
  @spec supports?(Path.t(), [requirement()]) :: {:ok, report()} | {:error, report()}
  def supports?(path, required) when is_list(required) do
    started = System.monotonic_time(:microsecond)
    requirements = Enum.map(required, &normalize_requirement/1)
    {validation, doc} = inspect_file(path)
    emit_validated(validation, path, started)

    {outcome, matched, missing} =
      if validation["valid"] do
        matched = Enum.map(requirements, &Map.put(&1, "events", matching_events(doc, &1)))

        missing =
          matched |> Enum.filter(&(&1["events"] == 0)) |> Enum.map(&Map.delete(&1, "events"))

        {if(missing == [], do: "supported", else: "incomplete"), matched, missing}
      else
        {"invalid", Enum.map(requirements, &Map.put(&1, "events", 0)), requirements}
      end

    report = %{
      "supported" => outcome == "supported",
      "outcome" => outcome,
      "required" => requirements,
      "matched" => matched,
      "missing" => missing,
      "artifact_path" => path,
      "artifact_sha256" => validation["artifact_sha256"],
      "checked_at" => now(),
      "validator" => identity(),
      "validation" => validation
    }

    emit_completeness(report, path, started)
    if outcome == "supported", do: {:ok, report}, else: {:error, report}
  end

  # --- reading ---------------------------------------------------------------

  defp inspect_file(path) do
    case File.read(path) do
      {:ok, bytes} ->
        sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        {acc, doc} = inspect_bytes(bytes)
        {report(acc, path, sha, byte_size(bytes)), doc}

      {:error, reason} ->
        acc = add_error(new_acc(), "", "unreadable_artifact", "cannot read artifact: #{reason}")
        {report(acc, path, nil, nil), nil}
    end
  end

  defp inspect_bytes(bytes) do
    case decode(bytes) do
      {:ok, doc} when is_map(doc) ->
        {check_document(doc, new_acc()), doc}

      {:ok, other} ->
        acc = add_error(new_acc(), "", "not_an_object", "top-level JSON value is #{kind(other)}")
        {acc, nil}

      {:error, message} ->
        {add_error(new_acc(), "", "non_json", "artifact is not JSON: #{message}"), nil}
    end
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # --- document --------------------------------------------------------------

  defp check_document(doc, acc) do
    acc =
      Enum.reduce(@top_level, acc, fn key, acc ->
        case Map.fetch(doc, key) do
          :error ->
            add_error(acc, "/" <> key, "missing_top_level_key", "required key #{key} is absent")

          {:ok, list} when is_list(list) ->
            acc

          {:ok, other} ->
            add_error(
              acc,
              "/" <> key,
              "invalid_type",
              "#{key} must be an array, got #{kind(other)}"
            )
        end
      end)

    object_types = list_at(doc, "objectTypes")
    event_types = list_at(doc, "eventTypes")
    objects = list_at(doc, "objects")
    events = list_at(doc, "events")

    {object_decls, acc} = check_type_decls(object_types, "/objectTypes", acc)
    {event_decls, acc} = check_type_decls(event_types, "/eventTypes", acc)
    {object_ids, acc} = collect_ids(objects, "/objects", "duplicate_object_id", "object", acc)
    {_event_ids, acc} = collect_ids(events, "/events", "duplicate_event_id", "event", acc)

    acc =
      objects
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {object, i}, acc ->
        check_object(object, "/objects/#{i}", object_decls, object_ids, acc)
      end)

    acc =
      events
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {event, i}, acc ->
        check_event(event, "/events/#{i}", event_decls, object_ids, acc)
      end)

    %{
      acc
      | counts: %{
          acc.counts
          | "object_types" => length(object_types),
            "event_types" => length(event_types),
            "objects" => length(objects),
            "events" => length(events)
        }
    }
  end

  defp list_at(doc, key) do
    case Map.get(doc, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # --- type declarations -------------------------------------------------------

  defp check_type_decls(decls, base, acc) do
    decls
    |> Enum.with_index()
    |> Enum.reduce({%{}, acc}, fn {decl, i}, {index, acc} ->
      path = "#{base}/#{i}"

      if is_map(decl) do
        {name, acc} = required_identifier(decl, "name", path, acc)
        {attrs, acc} = check_attribute_decls(decl, path, acc)

        cond do
          name == nil ->
            {index, acc}

          Map.has_key?(index, name) ->
            {index,
             add_error(
               acc,
               path <> "/name",
               "duplicate_type_name",
               "type #{inspect(name)} is declared more than once"
             )}

          true ->
            {Map.put(index, name, attrs), acc}
        end
      else
        {index, add_error(acc, path, "invalid_type", "type declaration must be an object")}
      end
    end)
  end

  defp check_attribute_decls(decl, path, acc) do
    case Map.fetch(decl, "attributes") do
      :error ->
        {%{},
         add_error(
           acc,
           path <> "/attributes",
           "missing_required_field",
           "type declaration requires an attributes array"
         )}

      {:ok, attrs} when is_list(attrs) ->
        attrs
        |> Enum.with_index()
        |> Enum.reduce({%{}, acc}, fn {attr, j}, {by_name, acc} ->
          apath = "#{path}/attributes/#{j}"
          check_attribute_decl(attr, apath, by_name, acc)
        end)

      {:ok, other} ->
        {%{},
         add_error(
           acc,
           path <> "/attributes",
           "invalid_type",
           "attributes must be an array, got #{kind(other)}"
         )}
    end
  end

  defp check_attribute_decl(attr, apath, by_name, acc) when is_map(attr) do
    {name, acc} = required_identifier(attr, "name", apath, acc)

    {type, acc} =
      case Map.fetch(attr, "type") do
        {:ok, type} when type in @attribute_types ->
          {type, acc}

        {:ok, type} ->
          {nil,
           add_error(
             acc,
             apath <> "/type",
             "invalid_attribute_type",
             "attribute type #{inspect(type)} is not one of #{Enum.join(@attribute_types, "|")}"
           )}

        :error ->
          {nil,
           add_error(
             acc,
             apath <> "/type",
             "missing_required_field",
             "attribute type is required"
           )}
      end

    cond do
      name == nil ->
        {by_name, acc}

      Map.has_key?(by_name, name) ->
        {by_name,
         add_error(
           acc,
           apath <> "/name",
           "duplicate_attribute_declaration",
           "attribute #{inspect(name)} is declared more than once on this type"
         )}

      true ->
        # An invalid declared type still declares the name, so uses of it are
        # not additionally reported as undeclared.
        {Map.put(by_name, name, type), acc}
    end
  end

  defp check_attribute_decl(_attr, apath, by_name, acc),
    do:
      {by_name, add_error(acc, apath, "invalid_type", "attribute declaration must be an object")}

  # --- identifiers -------------------------------------------------------------

  defp collect_ids(items, base, duplicate_code, noun, acc) do
    items
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), acc}, fn {item, i}, {ids, acc} ->
      path = "#{base}/#{i}"

      if is_map(item) do
        case required_identifier(item, "id", path, acc) do
          {nil, acc} ->
            {ids, acc}

          {id, acc} ->
            if MapSet.member?(ids, id) do
              {ids,
               add_error(
                 acc,
                 path <> "/id",
                 duplicate_code,
                 "#{noun} id #{inspect(id)} is not unique"
               )}
            else
              {MapSet.put(ids, id), acc}
            end
        end
      else
        {ids, add_error(acc, path, "invalid_type", "#{noun} must be an object")}
      end
    end)
  end

  defp required_identifier(map, key, path, acc) do
    case Map.fetch(map, key) do
      :error ->
        {nil, add_error(acc, "#{path}/#{key}", "missing_required_field", "#{key} is required")}

      {:ok, ""} ->
        {nil, add_error(acc, "#{path}/#{key}", "empty_identifier", "#{key} must not be empty")}

      {:ok, value} when is_binary(value) ->
        {value, acc}

      {:ok, other} ->
        {nil,
         add_error(
           acc,
           "#{path}/#{key}",
           "invalid_type",
           "#{key} must be a string, got #{kind(other)}"
         )}
    end
  end

  # --- objects -----------------------------------------------------------------

  defp check_object(object, path, decls, object_ids, acc) when is_map(object) do
    {declared, acc} = check_entity_type(object, path, decls, "undeclared_object_type", acc)

    acc =
      check_attribute_values(object, path, declared, acc, fn attr, apath, acc ->
        acc = bump(acc, "object_attributes")

        case Map.fetch(attr, "time") do
          :error ->
            add_error(
              acc,
              apath <> "/time",
              "missing_required_field",
              "object attribute time is required"
            )

          {:ok, time} ->
            check_time(time, apath <> "/time", acc)
        end
      end)

    check_relationships(object, path, object_ids, "object_object_relationships", acc)
  end

  defp check_object(_object, _path, _decls, _ids, acc), do: acc

  # --- events ------------------------------------------------------------------

  defp check_event(event, path, decls, object_ids, acc) when is_map(event) do
    {declared, acc} = check_entity_type(event, path, decls, "undeclared_event_type", acc)

    acc =
      case Map.fetch(event, "time") do
        :error ->
          add_error(acc, path <> "/time", "missing_required_field", "event time is required")

        {:ok, time} ->
          check_time(time, path <> "/time", acc)
      end

    acc =
      event
      |> Map.get("attributes")
      |> duplicate_attribute_names()
      |> Enum.reduce(acc, fn {name, j}, acc ->
        add_error(
          acc,
          "#{path}/attributes/#{j}/name",
          "duplicate_event_attribute",
          "event attribute #{inspect(name)} appears more than once"
        )
      end)

    acc =
      check_attribute_values(event, path, declared, acc, fn _attr, _apath, acc ->
        bump(acc, "event_attributes")
      end)

    check_relationships(event, path, object_ids, "event_object_relationships", acc)
  end

  defp check_event(_event, _path, _decls, _ids, acc), do: acc

  defp duplicate_attribute_names(attrs) when is_list(attrs) do
    attrs
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn
      {%{"name" => name}, j}, {seen, dups} when is_binary(name) ->
        if MapSet.member?(seen, name),
          do: {seen, [{name, j} | dups]},
          else: {MapSet.put(seen, name), dups}

      _, state ->
        state
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp duplicate_attribute_names(_), do: []

  # --- shared entity checks ------------------------------------------------------

  # Returns the declared attribute map for the entity's type, or :undeclared
  # when the type itself is missing/undeclared (attribute names then cannot be
  # judged and are not reported as a cascade).
  defp check_entity_type(entity, path, decls, undeclared_code, acc) do
    case required_identifier(entity, "type", path, acc) do
      {nil, acc} ->
        {:undeclared, acc}

      {type, acc} ->
        case Map.fetch(decls, type) do
          {:ok, attrs} ->
            {attrs, acc}

          :error ->
            {:undeclared,
             add_error(
               acc,
               path <> "/type",
               undeclared_code,
               "type #{inspect(type)} is not declared"
             )}
        end
    end
  end

  defp check_attribute_values(entity, path, declared, acc, extra) do
    case Map.fetch(entity, "attributes") do
      :error ->
        acc

      {:ok, attrs} when is_list(attrs) ->
        attrs
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {attr, j}, acc ->
          apath = "#{path}/attributes/#{j}"
          check_attribute_value(attr, apath, declared, acc, extra)
        end)

      {:ok, other} ->
        add_error(
          acc,
          path <> "/attributes",
          "invalid_type",
          "attributes must be an array, got #{kind(other)}"
        )
    end
  end

  defp check_attribute_value(attr, apath, declared, acc, extra) when is_map(attr) do
    {name, acc} = required_identifier(attr, "name", apath, acc)
    acc = extra.(attr, apath, acc)

    case {name, Map.fetch(attr, "value"), declared} do
      {_name, :error, _declared} ->
        add_error(acc, apath <> "/value", "missing_required_field", "attribute value is required")

      {nil, _value, _declared} ->
        acc

      {_name, _value, :undeclared} ->
        acc

      {name, {:ok, value}, declared} ->
        case Map.fetch(declared, name) do
          :error ->
            add_error(
              acc,
              apath <> "/name",
              "undeclared_attribute",
              "attribute #{inspect(name)} is not declared on this type"
            )

          {:ok, nil} ->
            acc

          {:ok, type} ->
            check_value(value, type, name, apath <> "/value", acc)
        end
    end
  end

  defp check_attribute_value(_attr, apath, _declared, acc, _extra),
    do: add_error(acc, apath, "invalid_type", "attribute must be an object")

  defp check_relationships(entity, path, object_ids, counter, acc) do
    case Map.fetch(entity, "relationships") do
      :error ->
        acc

      {:ok, rels} when is_list(rels) ->
        rels
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {rel, j}, acc ->
          check_relationship(rel, "#{path}/relationships/#{j}", object_ids, bump(acc, counter))
        end)

      {:ok, other} ->
        add_error(
          acc,
          path <> "/relationships",
          "invalid_type",
          "relationships must be an array, got #{kind(other)}"
        )
    end
  end

  defp check_relationship(rel, rpath, object_ids, acc) when is_map(rel) do
    acc =
      case required_identifier(rel, "objectId", rpath, acc) do
        {nil, acc} ->
          acc

        {object_id, acc} ->
          if MapSet.member?(object_ids, object_id),
            do: acc,
            else:
              add_error(
                acc,
                rpath <> "/objectId",
                "dangling_object_reference",
                "objectId #{inspect(object_id)} does not resolve to an object"
              )
      end

    case Map.fetch(rel, "qualifier") do
      :error ->
        add_error(acc, rpath <> "/qualifier", "missing_required_field", "qualifier is required")

      {:ok, qualifier} when is_binary(qualifier) ->
        acc

      {:ok, other} ->
        add_error(
          acc,
          rpath <> "/qualifier",
          "invalid_qualifier",
          "qualifier must be a string, got #{kind(other)}"
        )
    end
  end

  defp check_relationship(_rel, rpath, _ids, acc),
    do: add_error(acc, rpath, "invalid_type", "relationship must be an object")

  # --- values and time -----------------------------------------------------------

  defp check_value(value, type, name, vpath, acc) do
    case conforms(value, type) do
      :ok ->
        acc

      :no_offset ->
        warn(acc, "time_without_offset", vpath)

      :error ->
        add_error(
          acc,
          vpath,
          "attribute_value_type_mismatch",
          "attribute #{inspect(name)} is declared #{type} but has value #{inspect(value, limit: 5, printable_limit: 80)}"
        )
    end
  end

  defp conforms(value, "string") when is_binary(value), do: :ok
  defp conforms(value, "integer") when is_integer(value), do: :ok

  defp conforms(value, "integer") when is_binary(value),
    do: if(Regex.match?(~r/\A[+-]?\d+\z/, value), do: :ok, else: :error)

  defp conforms(value, "float") when is_number(value), do: :ok

  defp conforms(value, "float") when is_binary(value) do
    case Float.parse(value) do
      {_float, ""} -> :ok
      _ -> :error
    end
  end

  defp conforms(value, "boolean") when is_boolean(value), do: :ok
  defp conforms(value, "boolean") when value in ["true", "false"], do: :ok

  defp conforms(value, "time") when is_binary(value) do
    case parse_time(value) do
      :error -> :error
      other -> other
    end
  end

  defp conforms(_value, _type), do: :error

  defp check_time(time, tpath, acc) do
    case parse_time(time) do
      :ok ->
        acc

      :no_offset ->
        warn(acc, "time_without_offset", tpath)

      :error ->
        add_error(
          acc,
          tpath,
          "invalid_time",
          "#{inspect(time, limit: 5, printable_limit: 80)} is not an ISO-8601 date-time"
        )
    end
  end

  # Both parsers share Calendar.ISO's extended-format grammar and offset
  # validation, so "DateTime refuses but NaiveDateTime accepts" means exactly
  # "well-formed date-time without a UTC offset".
  defp parse_time(value) when is_binary(value) do
    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) -> :ok
      match?({:ok, _naive}, NaiveDateTime.from_iso8601(value)) -> :no_offset
      true -> :error
    end
  end

  defp parse_time(_value), do: :error

  # --- completeness --------------------------------------------------------------

  defp normalize_requirement(activity) when is_binary(activity),
    do: %{"activity" => activity, "attributes" => %{}}

  defp normalize_requirement({activity, attrs}) when is_binary(activity) and is_map(attrs) do
    %{
      "activity" => activity,
      "attributes" => Map.new(attrs, fn {k, v} -> {to_string(k), lexical(v)} end)
    }
  end

  defp normalize_requirement(other) do
    raise ArgumentError,
          "OCEL evidence requirement must be an activity string or {activity, %{attr => value}}, got: #{inspect(other)}"
  end

  defp matching_events(doc, %{"activity" => activity, "attributes" => required}) do
    doc
    |> Map.get("events", [])
    |> Enum.count(fn event ->
      event["type"] == activity and
        Enum.all?(required, fn {name, value} ->
          event
          |> Map.get("attributes", [])
          |> Enum.any?(&(&1["name"] == name and lexical(&1["value"]) == value))
        end)
    end)
  end

  defp lexical(value) when is_binary(value), do: value
  defp lexical(value) when is_atom(value), do: Atom.to_string(value)
  defp lexical(value) when is_integer(value), do: Integer.to_string(value)
  defp lexical(value) when is_float(value), do: Float.to_string(value)
  defp lexical(value), do: inspect(value)

  # --- accumulator & report --------------------------------------------------------

  defp new_acc do
    %{
      errors: [],
      error_count: 0,
      warnings: %{},
      counts: %{
        "object_types" => 0,
        "event_types" => 0,
        "objects" => 0,
        "events" => 0,
        "event_attributes" => 0,
        "object_attributes" => 0,
        "event_object_relationships" => 0,
        "object_object_relationships" => 0
      }
    }
  end

  defp add_error(acc, path, code, message) when code in @error_codes do
    errors =
      if acc.error_count < @max_errors,
        do: [%{"path" => path, "code" => code, "message" => message} | acc.errors],
        else: acc.errors

    %{acc | errors: errors, error_count: acc.error_count + 1}
  end

  defp warn(acc, code, path) do
    warnings =
      Map.update(
        acc.warnings,
        code,
        %{"code" => code, "count" => 1, "first_path" => path},
        fn w ->
          %{w | "count" => w["count"] + 1}
        end
      )

    %{acc | warnings: warnings}
  end

  defp bump(acc, counter), do: %{acc | counts: Map.update!(acc.counts, counter, &(&1 + 1))}

  defp report(acc, path, sha, bytes) do
    %{
      "valid" => acc.error_count == 0,
      "serialization" => @serialization,
      "validator" => identity(),
      "artifact_path" => path,
      "artifact_sha256" => sha,
      "artifact_bytes" => bytes,
      "validated_at" => now(),
      "counts" => acc.counts,
      "error_count" => acc.error_count,
      "errors" => Enum.reverse(acc.errors),
      "errors_truncated" => acc.error_count > @max_errors,
      "warnings" => acc.warnings |> Map.values() |> Enum.sort_by(& &1["code"])
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp kind(value) when is_map(value), do: "object"
  defp kind(value) when is_list(value), do: "array"
  defp kind(value) when is_binary(value), do: "string"
  defp kind(value) when is_boolean(value), do: "boolean"
  defp kind(nil), do: "null"
  defp kind(value) when is_integer(value), do: "integer"
  defp kind(value) when is_float(value), do: "float"
  defp kind(_value), do: "unknown"

  # --- telemetry -----------------------------------------------------------------

  defp emit_validated(report, path, started) do
    codes = report["errors"] |> Enum.map(& &1["code"]) |> Enum.uniq() |> Enum.sort()

    :telemetry.execute(
      @validated_event,
      %{
        error_count: report["error_count"],
        bytes: report["artifact_bytes"] || 0,
        duration_us: System.monotonic_time(:microsecond) - started
      },
      %{
        outcome: if(report["valid"], do: :valid, else: :invalid),
        error_count: report["error_count"],
        error_codes: Enum.join(codes, ","),
        artifact_sha256: report["artifact_sha256"],
        serialization: @serialization,
        validator: @name,
        validator_version: @version,
        path: path
      }
    )
  end

  defp emit_completeness(report, path, started) do
    missing = Enum.map(report["missing"], & &1["activity"])

    :telemetry.execute(
      @completeness_event,
      %{
        missing_count: length(missing),
        required_count: length(report["required"]),
        duration_us: System.monotonic_time(:microsecond) - started
      },
      %{
        outcome: completeness_outcome(report["outcome"]),
        missing: Enum.join(missing, ","),
        missing_count: length(missing),
        required_count: length(report["required"]),
        artifact_sha256: report["artifact_sha256"],
        validator: @name,
        validator_version: @version,
        path: path
      }
    )
  end

  defp completeness_outcome("supported"), do: :supported
  defp completeness_outcome("incomplete"), do: :incomplete
  defp completeness_outcome("invalid"), do: :invalid
end
