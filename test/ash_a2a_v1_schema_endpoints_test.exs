# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.V1SchemaEndpointsTest.Note do
  @moduledoc """
  Real fixture resource, private to this court: one `:read` and one `:create`
  action, the create carrying a required public `:title` string and an
  optional public `:views` integer, so the live skills schema endpoint has
  real typed content to serve (`AshA2A.Schema.for_skill/2` projects the
  create's accepted attributes).
  """

  use Ash.Resource,
    domain: AshA2A.V1SchemaEndpointsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:views, :integer, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      # An explicit accept: Ash's `defaults([:create])` leaves `accept: []`,
      # which projects an empty (vacuous) schema — the typed contract needs
      # the accepted attributes declared.
      accept([:title, :views])
    end
  end

  a2a do
    skill(:read_notes, :read)
    skill(:create_note, :create)
  end
end

defmodule AshA2A.V1SchemaEndpointsTest.Domain do
  @moduledoc "Real fixture domain for the resource above."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1SchemaEndpointsTest.Note)
  end
end

defmodule AshA2A.V1SchemaEndpointsTest.Agent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer over the fixture domain above, started per
  test under a unique registered name so parallel `async: true` runs never
  collide.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1SchemaEndpointsTest.Domain,
    name: "v1_schema_endpoints_agent"
end

defmodule AshA2A.V1SchemaEndpointsTest.MiniSchema do
  @moduledoc """
  A minimal JSON-Schema subset validator for the court: the keywords the
  served documents actually use (`$ref` into `#/$defs/`, `type`, `enum`,
  `required`, `properties`, `items`, `additionalProperties` as `false` or a
  schema, `anyOf`). Constraint keywords that need no structure check
  (`format`, `minLength`, `pattern`, ...) are ignored. Returns `:ok` or
  `{:error, [path, ... reasons]}`.
  """

  @spec validate(term(), map()) :: :ok | {:error, [String.t()]}
  def validate(instance, schema) when is_map(schema) do
    case walk(instance, schema, schema["$defs"] || %{}, "$") do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp walk(value, %{"$ref" => "#/$defs/" <> name} = schema, defs, path) do
    case Map.fetch(defs, name) do
      {:ok, target} -> walk(value, Map.drop(schema, ["$ref"]) |> Map.merge(target), defs, path)
      :error -> ["#{path}: unresolved $ref #/$defs/#{name}"]
    end
  end

  defp walk(value, %{"anyOf" => branches} = schema, defs, path) do
    remaining = Map.drop(schema, ["anyOf"])

    if Enum.any?(branches, fn branch -> walk(value, branch, defs, path) == [] end) do
      walk(value, remaining, defs, path)
    else
      ["#{path}: failed anyOf (#{length(branches)} branches)"]
    end
  end

  defp walk(value, schema, defs, path) do
    []
    |> type_errors(value, schema, path)
    |> enum_errors(value, schema, path)
    |> object_errors(value, schema, defs, path)
    |> array_errors(value, schema, defs, path)
  end

  defp type_errors(errors, value, %{"type" => type}, path) do
    ok? =
      case type do
        "object" -> is_map(value)
        "array" -> is_list(value)
        "string" -> is_binary(value)
        "integer" -> is_integer(value)
        "number" -> is_number(value)
        "boolean" -> is_boolean(value)
        "null" -> is_nil(value)
        _ -> true
      end

    if ok?, do: errors, else: ["#{path}: expected type #{type}"] ++ errors
  end

  defp type_errors(errors, _value, _schema, _path), do: errors

  defp enum_errors(errors, value, %{"enum" => enum}, path) do
    if value in enum, do: errors, else: ["#{path}: not in enum #{inspect(enum)}"] ++ errors
  end

  defp enum_errors(errors, _value, _schema, _path), do: errors

  defp object_errors(errors, value, schema, defs, path) do
    if is_map(value) do
      properties = Map.get(schema, "properties", %{})

      missing =
        for required <- Map.get(schema, "required", []),
            not Map.has_key?(value, required) do
          "#{path}: missing required member #{required}"
        end

      property_errors =
        for {key, sub} <- properties, Map.has_key?(value, key) do
          walk(value[key], sub, defs, path <> "." <> key)
        end

      additional =
        case schema["additionalProperties"] do
          false ->
            for key <- Map.keys(value), not Map.has_key?(properties, key) do
              ["#{path}: additional property #{key} not allowed"]
            end

          sub when is_map(sub) ->
            for {key, v} <- value, not Map.has_key?(properties, key) do
              walk(v, sub, defs, path <> "." <> key)
            end

          _ ->
            []
        end

      Enum.reverse(missing) ++
        Enum.flat_map(Enum.reverse(property_errors), & &1) ++
        Enum.flat_map(Enum.reverse(additional), & &1) ++
        errors
    else
      errors
    end
  end

  defp array_errors(errors, value, %{"items" => items}, defs, path) when is_list(value) do
    item_errors =
      value
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> walk(item, items, defs, "#{path}[#{index}]") end)

    Enum.flat_map(Enum.reverse(item_errors), & &1) ++ errors
  end

  defp array_errors(errors, _value, _schema, _defs, _path), do: errors
end

defmodule AshA2A.V1SchemaEndpointsTest do
  @moduledoc """
  Court for the machine-readable schema endpoints (Workstream3 G4):
  `AshA2A.Transport.SchemaEndpoints` mounted in `AshA2A.Transport.Plug` and
  `AshA2A.Transport.HTTPJSON` behind `serve_schemas: true`.

  Real plug GETs against a real, running `AshA2A.Agent` GenServer over a real
  Ash fixture domain -- no mocks. The falsifier: the card schema endpoint's
  document validates the REAL served agent card fetched from the same mount
  (and rejects mutated cards -- anti-vacuity), and the skills schema
  endpoint's document is keyed by exactly the served card's skill ids with
  schemas equal to the independently computed `AshA2A.Schema.for_skill/2`
  projections from the same compiled capability index.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Transport.HTTPJSON, as: Rest
  alias AshA2A.Transport.Plug, as: Rpc

  @domain AshA2A.V1SchemaEndpointsTest.Domain
  @card_schema_path "/.well-known/agent-card.schema.json"
  @skills_schema_path "/.well-known/skills.schema.json"
  @card_path "/.well-known/agent-card.json"

  setup do
    agent_name = :"v1_schema_endpoints_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = AshA2A.V1SchemaEndpointsTest.Agent.start_link(name: agent_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{agent: agent_name}
  end

  defp rpc_opts(agent, extra \\ []) do
    Rpc.init(
      [agent: agent, base_url: "http://localhost:4000/a2a", serve_schemas: true, schema_index: @domain] ++
        extra
    )
  end

  defp rest_opts(agent) do
    Rest.init(agent: agent, base_url: "http://localhost:4000", serve_schemas: true, schema_index: @domain)
  end

  defp get_rpc(_agent, path, opts), do: Plug.Test.conn(:get, path) |> Rpc.call(opts)
  defp post_rpc(_agent, path, opts), do: Plug.Test.conn(:post, path, "") |> Rpc.call(opts)
  defp get_rest(path, opts), do: Plug.Test.conn(:get, path) |> Rest.call(opts)

  # -- agent-card.schema.json ---------------------------------------------------

  test "RPC plug serves the static card schema document", %{agent: agent} do
    conn = get_rpc(agent, @card_schema_path, rpc_opts(agent))

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    schema = Jason.decode!(conn.resp_body)
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["title"] == "A2A v1.0 AgentCard"

    # Hand-authored from the v1.0 proto: the REQUIRED AgentCard members
    # (a2a.proto lines 391-415, field_behavior = REQUIRED) and the TaskState
    # enum (a2a.proto lines 211-233) are pinned.
    assert schema["required"] == [
             "name",
             "description",
             "version",
             "skills",
             "capabilities",
             "defaultInputModes",
             "defaultOutputModes",
             "supportedInterfaces"
           ]

    assert schema["properties"]["supportedInterfaces"]["items"]["$ref"] == "#/$defs/AgentInterface"

    assert schema["$defs"]["AgentInterface"]["required"] == [
             "url",
             "protocolBinding",
             "protocolVersion"
           ]

    assert %{"type" => "string", "enum" => states} = schema["$defs"]["TaskState"]
    assert length(states) == 9
    assert "TASK_STATE_WORKING" in states
    assert "TASK_STATE_AUTH_REQUIRED" in states

    # The same static document is served through the REST binding.
    rest_conn = get_rest(@card_schema_path, rest_opts(agent))
    assert rest_conn.status == 200
    assert Jason.decode!(rest_conn.resp_body) == schema
  end

  test "the card schema validates the REAL served agent card (same mount)", %{agent: agent} do
    opts = rpc_opts(agent)

    schema =
      get_rpc(agent, @card_schema_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    served_card = get_rpc(agent, @card_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    assert :ok = AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(served_card, schema)

    # Concretely: the real card's members the schema pins are on the wire.
    assert is_binary(served_card["name"])
    assert [%{"protocolBinding" => "JSONRPC", "protocolVersion" => "1.0"} | _] =
             served_card["supportedInterfaces"]

    assert [%{"id" => _id, "name" => _name, "description" => _desc, "tags" => _tags} | _] =
             served_card["skills"]
  end

  test "the card schema has teeth: mutated cards are rejected (anti-vacuity)", %{agent: agent} do
    opts = rpc_opts(agent)

    schema =
      get_rpc(agent, @card_schema_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    served_card = get_rpc(agent, @card_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    # A required member dropped -> invalid.
    missing_name = Map.drop(served_card, ["name"])
    assert {:error, [_]} = AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(missing_name, schema)

    # A supportedInterfaces item missing its REQUIRED protocolBinding
    # (a2a.proto:368-375) -> invalid at the item level.
    card =
      update_in(served_card, ["supportedInterfaces"], fn [first | rest] ->
        [Map.drop(first, ["protocolBinding"]) | rest]
      end)

    assert {:error, errors} = AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(card, schema)
    assert Enum.any?(errors, &String.contains?(&1, "protocolBinding"))

    # A member the v1.0 proto does not define -> additionalProperties refusal.
    legacy = Map.put(served_card, "preferredTransport", "JSONRPC")
    assert {:error, errors} = AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(legacy, schema)
    assert Enum.any?(errors, &String.contains?(&1, "preferredTransport"))
  end

  test "served card protocolBinding values are pinned by the court, not the open schema (lane X7)", %{
    agent: agent
  } do
    opts = rpc_opts(agent)

    schema =
      get_rpc(agent, @card_schema_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    served_card = get_rpc(agent, @card_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    # The schema deliberately keeps protocolBinding an open string (a2a.proto
    # types it as a plain string): a bogus binding is schema-VALID, so the
    # card-level pin lives in THIS court, not in the document.
    pigeon =
      update_in(served_card, ["supportedInterfaces"], fn [first | rest] ->
        [Map.put(first, "protocolBinding", "CARRIER_PIGEON") | rest]
      end)

    assert :ok = AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(pigeon, schema)

    # The court's allowed set: the documented core bindings (spec §4.4/8.2)
    # union the consumer-declared bindings, read from the same config the
    # card builder reads (AshA2A.Info.default_supported_interfaces/2 ->
    # AshA2A.Domain.Info.supported_interfaces/1).
    declared =
      @domain
      |> AshA2A.Domain.Info.supported_interfaces()
      |> Enum.map(& &1.protocol_binding)

    allowed =
      MapSet.union(MapSet.new(["JSONRPC", "GRPC", "HTTP+JSON"]), MapSet.new(declared))

    bindings = Enum.map(served_card["supportedInterfaces"], & &1["protocolBinding"])
    assert bindings != []

    Enum.each(bindings, fn binding ->
      assert binding in MapSet.to_list(allowed),
             "served protocolBinding #{inspect(binding)} outside core set ∪ " <>
               "consumer-declared #{inspect(MapSet.to_list(allowed))}"
    end)

    # Teeth: the same membership predicate rejects the mutant.
    assert "CARRIER_PIGEON" not in MapSet.to_list(allowed)
  end

  # -- skills.schema.json ---------------------------------------------------------

  test "skills schema is live from the served agent's capability index", %{agent: agent} do
    opts = rpc_opts(agent)

    conn = get_rpc(agent, @skills_schema_path, opts)
    assert conn.status == 200

    doc = Jason.decode!(conn.resp_body)

    # Keyed by exactly the served card's skill ids (join surface).
    served_card = get_rpc(agent, @card_path, opts) |> Map.fetch!(:resp_body) |> Jason.decode!()

    card_ids = Enum.map(served_card["skills"], & &1["id"]) |> MapSet.new()
    assert MapSet.equal?(MapSet.new(Map.keys(doc["skills"])), card_ids)
    assert doc["omitted"] == []

    # The create skill's schema is the real, independently computed projection:
    # required :title (allow_nil? false, public?), optional :views integer.
    # Skill ids are the canonical "<Resource>.<action>" identity
    # (AshA2A.CapabilityIndex.Compiler.capability_id/2), so the create skill's
    # id carries the Ash action name (:create), not the declared skill name.
    skill = @domain |> AshA2A.Info.capability_index!() |> Enum.find(&(&1.action == :create))
    create_id = skill.id

    assert create_id == "AshA2A.V1SchemaEndpointsTest.Note.create"

    expected =
      AshA2A.Schema.for_skill(skill, skill.resource) |> elem(1)

    assert doc["skills"][create_id] == expected
    assert doc["skills"][create_id]["required"] == ["title"]
    assert doc["skills"][create_id]["properties"]["title"] == %{"type" => "string"}
    assert doc["skills"][create_id]["properties"]["views"] == %{"type" => "integer"}

    # And the served skill schema accepts a real conforming input and refuses
    # a non-conforming one (the checker has teeth on the served schema).
    assert :ok =
             AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(
               %{"title" => "hello", "views" => 1},
               doc["skills"][create_id]
             )

    assert {:error, [_ | _]} =
             AshA2A.V1SchemaEndpointsTest.MiniSchema.validate(
               %{"title" => "hello", "bogus" => 1},
               doc["skills"][create_id]
             )

    # Same live document through the REST binding.
    rest_conn = get_rest(@skills_schema_path, rest_opts(agent))
    assert rest_conn.status == 200
    assert Jason.decode!(rest_conn.resp_body) == doc
  end

  test "REST binding serves both schema endpoints identically", %{agent: agent} do
    opts = rest_opts(agent)

    card_schema = get_rest(@card_schema_path, opts)
    skills_schema = get_rest(@skills_schema_path, opts)

    assert card_schema.status == 200 and skills_schema.status == 200
    assert card_schema.resp_body == Jason.encode!(Jason.decode!(card_schema.resp_body))
    assert skills_schema.resp_body == Jason.encode!(Jason.decode!(skills_schema.resp_body))
    assert Jason.decode!(card_schema.resp_body) == AshA2A.Transport.SchemaEndpoints.agent_card_schema()
  end

  # -- mounting --------------------------------------------------------------------

  test "both endpoints answer 405 with allow: GET on a non-GET method", %{agent: agent} do
    opts = rpc_opts(agent)

    conn = post_rpc(agent, @card_schema_path, opts)
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]

    conn = post_rpc(agent, @skills_schema_path, opts)
    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end

  test "default mount (no serve_schemas) leaves both paths 404 on both bindings", %{agent: agent} do
    rpc = Rpc.init(agent: agent, base_url: "http://localhost:4000/a2a")
    rest = Rest.init(agent: agent, base_url: "http://localhost:4000")

    for path <- [@card_schema_path, @skills_schema_path] do
      assert get_rpc(agent, path, rpc).status == 404
      assert get_rest(path, rest).status == 404
    end
  end

  test "serve_schemas: true without :schema_index is a boot-time refusal", %{agent: agent} do
    assert_raise ArgumentError, ~r/requires a :schema_index/, fn ->
      Rpc.init(agent: agent, base_url: "http://localhost:4000/a2a", serve_schemas: true)
    end

    assert_raise ArgumentError, ~r/requires a :schema_index/, fn ->
      Rest.init(agent: agent, base_url: "http://localhost:4000", serve_schemas: true)
    end
  end
end
