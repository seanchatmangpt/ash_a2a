defmodule AshA2A.Schema do
  @moduledoc """
  JSON-Schema (Draft 2020-12) projection of Ash action arguments, for skill
  cards (Zach-Daniel target: skills advertise JSON Schema the way
  `ash_json_api`/`OpenApi` or `ash_ai`'s tool schemas do).

  One canonical Ash-native projection, so A2A skill cards never hand-write
  per-skill schemas. The Ash type -> JSON-Schema mapping table:

      | Ash type                        | JSON-Schema                                              |
      |---------------------------------|----------------------------------------------------------|
      | `:string` / `:ci_string`        | `{"type": "string"}` (+ minLength/maxLength/pattern/enum) |
      | `:integer`                      | `{"type": "integer"}` (+ minimum/maximum)                 |
      | `:decimal` / `:float` (`number`)| `{"type": "number"}` (+ minimum/maximum)                  |
      | `:boolean`                      | `{"type": "boolean"}`                                     |
      | `:map` / `:keyword`             | `{"type": "object"}` (recursive on `constraints[:fields]`) |
      | `{:array, t}`                   | `{"type": "array", "items": <t>}`                         |
      | `:date`                         | `{"type": "string", "format": "date"}`                    |
      | `:time` / `:time_usec`          | `{"type": "string", "format": "time"}`                    |
      | `:utc_datetime(_usec)` / `:datetime` / `:naive_datetime` | `{"type": "string", "format": "date-time"}` |
      | `:uuid` / `:uuid_v7`            | `{"type": "string", "format": "uuid"}`                    |
      | `:atom` (with `one_of`)         | `{"type": "string", "enum": [...]}`                       |
      | `Ash.Type.Enum` modules         | `{"type": "string", "enum": [...]}`                       |
      | `:union`                        | `{"anyOf": [...]}`                                        |
      | `:struct` / embedded resources  | `{"type": "object"}` (recursive attributes)               |
      | NewTypes                        | recursion into `subtype_of` with merged constraints       |
      | anything else (`:term`, `:binary`, `:file`, ...) | `{:error, {:unserializable_type, type}}` |

  A type the projection cannot represent is never silently degraded to a
  loose schema: it returns `{:error, {:unserializable_type, type}}` so
  verifiers can warn on exactly those skills.

  ## Examples

  Projection of a real action's arguments (fixture:
  `AshA2A.Test.Fixture.TypedArguments` -- `:query` required string, `:limit`
  optional integer):

      iex> {:ok, schema} = AshA2A.Schema.for_action(AshA2A.Test.Fixture.TypedArguments, :search)
      iex> schema["type"]
      "object"
      iex> schema["required"]
      ["query"]
      iex> schema["properties"]["query"]
      %{"type" => "string"}
      iex> schema["properties"]["limit"]
      %{"type" => "integer"}
      iex> schema["additionalProperties"]
      false

  `for_skill/2` honors `argument_mapping` (wire names are the mapped string
  keys):

      iex> skill = %AshA2A.Skill{action: :search, argument_mapping: %{"q" => :query}}
      iex> {:ok, schema} = AshA2A.Schema.for_skill(skill, AshA2A.Test.Fixture.TypedArguments)
      iex> schema["required"]
      ["q"]
      iex> schema["properties"]["q"]
      %{"type" => "string"}

  An unrepresentable argument type is an error, not a silent loose schema:

      iex> action = %Ash.Resource.Actions.Action{
      ...>   name: :f,
      ...>   arguments: [%Ash.Resource.Actions.Argument{
      ...>     name: :blob, type: :term, constraints: [], allow_nil?: false, public?: true
      ...>   }]
      ...> }
      iex> AshA2A.Schema.for_action(action, :f)
      {:error, {:unserializable_type, :term}}
  """

  @typedoc "A JSON-Schema (Draft 2020-12) fragment with string keys."
  @type schema :: %{optional(String.t()) => term()}

  @typedoc "`{:ok, schema}` on full coverage, `{:error, {:unserializable_type, type}}` otherwise."
  @type result :: {:ok, schema()} | {:error, {:unserializable_type, term()}}

  @doc """
  Builds the Draft 2020-12 object schema for one Ash action's input.

  Accepts either a resource module (the canonical path: the action is looked
  up by name and accepted attributes from `action.accept` are projected
  alongside the action's declared `argument`s) or an action struct (in which
  case accepted attributes are only projected when `opts[:resource]` is
  supplied, because an Ash action struct does not reference its resource).

  Returns `{:ok, schema}` or `{:error, {:unserializable_type, type}}` when
  any argument or accepted attribute has a type this projection cannot
  represent. Raises `ArgumentError` for an unknown action name on a resource
  module.

  ## Examples

      iex> {:ok, schema} = AshA2A.Schema.for_action(AshA2A.Test.Fixture.TypedArguments, :search)
      iex> schema["properties"] |> Map.keys() |> Enum.sort()
      ["limit", "query"]

  """

  @spec for_action(module() | map(), atom() | nil, keyword()) :: result()
  def for_action(resource_or_action, action_name \\ nil, opts \\ [])

  def for_action(resource, action_name, _opts) when is_atom(resource) do
    action =
      Ash.Resource.Info.action(resource, action_name) ||
        raise ArgumentError,
              "unknown action #{inspect(action_name)} on resource #{inspect(resource)}"

    build(resource, action)
  end

  def for_action(action, _action_name, opts) when is_map(action) do
    build(Keyword.get(opts, :resource), action)
  end

  @doc """
  Builds the schema for a skill's action, honoring the skill's
  `argument_mapping`.

  Wire names are the mapped string keys of `argument_mapping`
  (`%{wire_name => action_argument}`); unmapped arguments pass through under
  `to_string/1` of their action argument name. `argument_mapping` is read
  defensively via `Map.get/2` so raw DSL entities or older struct versions
  without the field still project with pass-through names.

  ## Examples

      iex> skill = %AshA2A.Skill{action: :search, argument_mapping: %{"q" => :query}}
      iex> {:ok, schema} = AshA2A.Schema.for_skill(skill, AshA2A.Test.Fixture.TypedArguments)
      iex> schema["properties"] |> Map.keys() |> Enum.sort()
      ["limit", "q"]
      iex> schema["required"]
      ["q"]

  """

  @spec for_skill(AshA2A.Skill.t(), module()) :: result()
  def for_skill(%AshA2A.Skill{} = skill, resource) do
    mapping = Map.get(skill, :argument_mapping) || %{}

    wire_name = fn argument_name ->
      Enum.find_value(mapping, to_string(argument_name), fn {wire, arg} ->
        if to_string(arg) == to_string(argument_name), do: to_string(wire)
      end)
    end

    with {:ok, schema} <- for_action(resource, skill.action) do
      {:ok,
       %{
         "type" => "object",
         "properties" => Map.new(schema["properties"], fn {name, sub} -> {wire_name.(name), sub} end),
         "required" => Enum.map(schema["required"], wire_name),
         "additionalProperties" => false
       }}
    end
  end

  # -- action -> fields --

  defp build(nil, action) do
    build_fields(arguments(action), [])
  end

  defp build(resource, action) do
    accept = action |> Map.get(:accept) |> List.wrap()

    accepted_attributes =
      if accept == [] do
        []
      else
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&(&1.name in accept && &1.public?))
      end

    build_fields(arguments(action), accepted_attributes)
  end

  defp arguments(action), do: action.arguments |> List.wrap() |> Enum.filter(& &1.public?)

  # Arguments win over same-named accepted attributes (mirrors Ash input
  # semantics and ash_ai's projection order).
  defp build_fields(arguments, accepted_attributes) do
    argument_names = MapSet.new(arguments, & &1.name)

    fields =
      arguments ++ Enum.reject(accepted_attributes, &MapSet.member?(argument_names, &1.name))

    {properties, required, errors} =
      Enum.reduce(fields, {%{}, [], []}, fn field, {props, required, errors} ->
        case field_schema(field) do
          {:ok, sub} ->
            {Map.put(props, to_string(field.name), with_description(sub, field)),
             maybe_required(field) ++ required, errors}

          {:error, _} = error ->
            {props, required, [error | errors]}
        end
      end)

    case errors do
      [] ->
        {:ok,
         %{
           "type" => "object",
           "properties" => properties,
           "required" => Enum.reverse(required),
           "additionalProperties" => false
         }}

      [error | _] ->
        error
    end
  end

  defp maybe_required(%{allow_nil?: false, name: name}), do: [to_string(name)]
  defp maybe_required(_), do: []

  defp with_description(schema, %{description: desc}) when is_binary(desc),
    do: Map.put(schema, "description", desc)

  defp with_description(schema, _), do: schema

  # -- per-field type projection --

  defp field_schema(field) do
    type_schema(field.type, field.constraints || [])
  end

  defp type_schema({:array, inner}, constraints) do
    case type_schema(inner, constraints[:items] || []) do
      {:ok, items} ->
        {:ok,
         %{"type" => "array", "items" => items}
         |> put_constraint(constraints, :min_length, "minItems")
         |> put_constraint(constraints, :max_length, "maxItems")}

      {:error, _} = error ->
        error
    end
  end

  defp type_schema(type, constraints) do
    normalized = Ash.Type.get_type(type)

    cond do
      normalized == Ash.Type.String or normalized == Ash.Type.CiString ->
        {:ok, string_schema(constraints)}

      normalized == Ash.Type.Integer ->
        {:ok, number_schema(%{"type" => "integer"}, constraints)}

      normalized == Ash.Type.Float or normalized == Ash.Type.Decimal ->
        {:ok, number_schema(%{"type" => "number"}, constraints)}

      normalized == Ash.Type.Boolean ->
        {:ok, %{"type" => "boolean"}}

      normalized == Ash.Type.Date ->
        {:ok, formatted_string("date")}

      normalized in [Ash.Type.Time, Ash.Type.TimeUsec] ->
        {:ok, formatted_string("time")}

      normalized in [Ash.Type.DateTime, Ash.Type.NaiveDatetime, Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec] ->
        {:ok, formatted_string("date-time")}

      normalized in [Ash.Type.UUID, Ash.Type.UUIDv7] ->
        {:ok, formatted_string("uuid")}

      normalized == Ash.Type.Atom ->
        atom_schema(constraints)

      normalized == Ash.Type.DurationName ->
        {:ok, enum_schema(Enum.map(Ash.Type.DurationName.values(), &to_string/1))}

      normalized in [Ash.Type.Map, Ash.Type.Keyword] ->
        map_schema(constraints)

      normalized == Ash.Type.Union ->
        union_schema(constraints)

      normalized == Ash.Type.Struct ->
        struct_schema(constraints)

      normalized != nil and Ash.Type.NewType.new_type?(normalized) ->
        merged = Ash.Type.NewType.constraints(normalized, constraints)
        type_schema(Ash.Type.get_type(Ash.Type.NewType.subtype_of(normalized)), merged)

      embedded_resource?(normalized) ->
        embedded_schema(normalized)

      is_atom(normalized) and Spark.implements_behaviour?(normalized, Ash.Type.Enum) ->
        {:ok, enum_schema(Enum.map(normalized.values(), &to_string/1))}

      true ->
        {:error, {:unserializable_type, type}}
    end
  end

  # -- scalar schemas + constraints --

  defp string_schema(constraints) do
    %{"type" => "string"}
    |> put_constraint(constraints, :min_length, "minLength")
    |> put_constraint(constraints, :max_length, "maxLength")
    |> Map.merge(match_constraint(constraints))
    |> Map.merge(one_of_constraint(constraints))
  end

  defp number_schema(schema, constraints) do
    schema
    |> put_constraint(constraints, :min, "minimum")
    |> put_constraint(constraints, :max, "maximum")
  end

  defp put_constraint(schema, constraints, key, json_key) do
    case constraints[key] do
      nil -> schema
      value -> Map.put(schema, json_key, value)
    end
  end

  defp match_constraint(constraints) do
    case constraints[:match] do
      %Regex{} = regex -> %{"pattern" => Regex.source(regex)}
      match when is_binary(match) -> %{"pattern" => match}
      _ -> %{}
    end
  end

  defp one_of_constraint(constraints) do
    case constraints[:one_of] do
      nil -> %{}
      one_of -> %{"enum" => one_of}
    end
  end

  defp atom_schema(constraints) do
    case constraints[:one_of] do
      nil -> {:ok, %{"type" => "string"}}
      one_of -> {:ok, %{"type" => "string", "enum" => Enum.map(one_of, &to_string/1)}}
    end
  end

  defp enum_schema(values), do: %{"type" => "string", "enum" => values}

  defp formatted_string(format), do: %{"type" => "string", "format" => format}

  # -- object schemas (map/keyword/struct/embedded) --

  defp map_schema(constraints) do
    case constraints[:fields] do
      fields when fields in [nil, []] ->
        {:ok, %{"type" => "object"}}

      fields ->
        with {:ok, {properties, required}} <- map_fields(fields) do
          {:ok,
           %{
             "type" => "object",
             "properties" => properties,
             "required" => required,
             "additionalProperties" => false
           }}
        end
    end
  end

  # Field configs are keyword lists: [type: t, constraints: [...],
  # allow_nil?: bool, description: s].
  defp map_fields(fields) do
    {properties, required, errors} =
      Enum.reduce(fields, {%{}, [], []}, fn {key, config}, {props, required, errors} ->
        case type_schema(config[:type], config[:constraints] || []) do
          {:ok, sub} ->
            sub =
              case config[:description] do
                nil -> sub
                desc -> Map.put(sub, "description", desc)
              end

            required =
              if config[:allow_nil?] == false, do: required ++ [to_string(key)], else: required

            {Map.put(props, to_string(key), sub), required, errors}

          {:error, _} = error ->
            {props, required, [error | errors]}
        end
      end)

    case errors do
      [] -> {:ok, {properties, required}}
      [error | _] -> error
    end
  end

  defp union_schema(constraints) do
    case constraints[:types] do
      nil ->
        {:ok, %{"anyOf" => []}}

      types ->
        {schemas, errors} =
          Enum.reduce(types, {[], []}, fn {_name, config}, {schemas, errors} ->
            case type_schema(config[:type], config[:constraints] || []) do
              {:ok, sub} -> {[sub | schemas], errors}
              {:error, _} = error -> {schemas, [error | errors]}
            end
          end)

        case errors do
          [] -> {:ok, %{"anyOf" => Enum.reverse(schemas)}}
          [error | _] -> error
        end
    end
  end

  defp struct_schema(constraints) do
    case constraints[:instance_of] do
      instance_of when is_atom(instance_of) and not is_nil(instance_of) ->
        if embedded_resource?(instance_of) do
          embedded_schema(instance_of)
        else
          {:ok, %{"type" => "object"}}
        end

      _ ->
        {:ok, %{"type" => "object"}}
    end
  end

  defp embedded_resource?(type) do
    is_atom(type) and not is_nil(type) and Code.ensure_loaded(type) == {:module, type} and
      Ash.Resource.Info.resource?(type) and Ash.Resource.Info.embedded?(type)
  end

  defp embedded_schema(resource) do
    {properties, required, errors} =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.public?)
      |> Enum.reduce({%{}, [], []}, fn attribute, {props, required, errors} ->
        case type_schema(attribute.type, attribute.constraints || []) do
          {:ok, sub} ->
            {Map.put(props, to_string(attribute.name), with_description(sub, attribute)),
             maybe_required(attribute) ++ required, errors}

          {:error, _} = error ->
            {props, required, [error | errors]}
        end
      end)

    case errors do
      [] ->
        {:ok,
         %{
           "type" => "object",
           "properties" => properties,
           "required" => Enum.reverse(required),
           "additionalProperties" => false
         }}

      [error | _] ->
        error
    end
  end
end
