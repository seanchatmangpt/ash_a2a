# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Transport.SchemaEndpoints do
  @moduledoc """
  Machine-readable schema endpoints for the ash_a2a transports
  (the `ash_json_api` precedent: a served API also serves the machine-readable
  spec of what it serves, as router endpoints).

  Two `GET` well-known endpoints, mounted by `AshA2A.Transport.Plug` and
  `AshA2A.Transport.HTTPJSON` when the mount passes `serve_schemas: true`:

      GET /.well-known/agent-card.schema.json
        The JSON Schema (Draft 2020-12) OF the A2A v1.0 AgentCard wire shape
        -- a static document, hand-authored from the v1.0 proto with proto
        line citations, describing the exact members the in-repo codec
        (`AshA2A.Protocol.JSON.encode_agent_card/2`) emits.

      GET /.well-known/skills.schema.json
        Per-skill JSON Schema (Draft 2020-12) generated LIVE via
        `AshA2A.Schema.for_skill/2` from the served agent's compiled
        capability index, keyed by the same skill id the card's
        `skills[].id` uses (so a client can join the two surfaces by id).

  ## Mounting

      plug AshA2A.Transport.Plug,
        agent: MyAgent,
        base_url: "https://x/a2a",
        serve_schemas: true,
        # the capability-index source for the live skills schema: a resource
        # or `Ash.Domain` with the `AshA2A` extension, a zero-arity fun
        # returning the skill list, or a prebuilt `%AshA2A.Skill{}` list
        schema_index: MyDomain

  `serve_schemas: true` without a `:schema_index` is a boot-time
  `ArgumentError` (fail closed: an enabled skills endpoint without a
  capability-index source would otherwise have to serve `404` per request, or
  an empty schema document, and neither is honest). With the flag unset (the
  default `false`) both paths answer `404` -- the endpoints do not exist.

  ## Wire facts the schema pins (anti-drift)

  The schema is `additionalProperties: false` over exactly the members the
  codec emits (priv/proto/a2a.proto, `message AgentCard`, fields 1-14,
  lines 386-418; wire member names are the protojson camelCase names):

    * required: `name`, `description`, `version`, `skills`,
      `capabilities`, `defaultInputModes`, `defaultOutputModes`,
      `supportedInterfaces` (AgentCard fields 1, 2, 5, 12, 7, 10, 11, 3 --
      all `REQUIRED` field_behavior, a2a.proto lines 391-415);
    * `supportedInterfaces` items require `url`, `protocolBinding`,
      `protocolVersion` (AgentInterface fields 1/2/4, a2a.proto lines
      365-375);
    * `skills` items require `id`, `name`, `description`, `tags`
      (AgentSkill fields 1-4, a2a.proto lines 464-471);
    * `capabilities` members `streaming`/`pushNotifications`/
      `extendedAgentCard` are optional booleans, `extensions` an optional
      array of `{uri, required, description?, params?}` (AgentCapabilities
      fields 1-4 + AgentExtension fields 1-4, a2a.proto lines 436-459) --
      the v1.0 proto has no `stateTransitionHistory` member (it was dropped
      in v1.0, Z16-F3) and no `preferredTransport` member (transport
      preference is positional over `supportedInterfaces`, a2a.proto:370);
    * `$defs.TaskState` carries the nine proto enum values verbatim
      (`TASK_STATE_UNSPECIFIED` .. `TASK_STATE_AUTH_REQUIRED`,
      a2a.proto lines 211-233), the exact strings the codec emits on the
      tasks surface (`AshA2A.Protocol.JSON` state table).
  """

  alias AshA2A.Schema

  @card_schema_path [".well-known", "agent-card.schema.json"]
  @skills_schema_path [".well-known", "skills.schema.json"]

  @typedoc "The pinned schema-endpoint options map fragment produced by `init/1`."
  @type opts :: %{
          required(:serve_schemas) => boolean(),
          required(:schema_index) =>
            module() | (-> [AshA2A.Skill.t()]) | [AshA2A.Skill.t()] | nil
        }

  @doc "The two schema endpoint path segments, for plug-path dispatch."
  @spec paths() :: [[String.t(), ...]]
  def paths, do: [@card_schema_path, @skills_schema_path]

  @doc """
  Resolves and validates the schema-endpoint options from the mounting
  plug's opts. Fail closed at boot: `serve_schemas: true` requires a
  `:schema_index`, and a non-boolean flag or a malformed index source is
  refused rather than degraded.
  """
  @spec init(keyword()) :: opts()
  def init(opts) when is_list(opts) do
    serve_schemas = Keyword.get(opts, :serve_schemas, false)
    schema_index = Keyword.get(opts, :schema_index)

    unless is_boolean(serve_schemas) do
      raise ArgumentError, ":serve_schemas must be a boolean, got: #{inspect(serve_schemas)}"
    end

    if serve_schemas and is_nil(schema_index) do
      raise ArgumentError,
            "serve_schemas: true requires a :schema_index (a resource or Ash.Domain with " <>
              "the AshA2A extension, a zero-arity fun returning the skill list, or a " <>
              "prebuilt %AshA2A.Skill{} list) -- a live skills schema endpoint cannot " <>
              "be served without a capability-index source"
    end

    validate_index!(schema_index)

    %{serve_schemas: serve_schemas, schema_index: schema_index}
  end

  defp validate_index!(nil), do: :ok
  defp validate_index!(index) when is_function(index, 0), do: :ok
  defp validate_index!(index) when is_atom(index), do: :ok
  defp validate_index!(index) when is_list(index), do: :ok

  defp validate_index!(other),
    do:
      raise(
        ArgumentError,
        ":schema_index must be a resource/domain module, a zero-arity fun or a " <>
          "%AshA2A.Skill{} list, got: #{inspect(other)}"
      )

  @doc """
  Serves one schema endpoint for the mounting plug, or `:next` when the
  endpoints are disabled (the plug falls through to its own `404`).

  `GET` on either path with `serve_schemas: true` answers `200`
  `application/json`; a non-`GET` method with the flag on answers `405` with
  an `allow: GET` header (the endpoints are visible, the verb is not
  served); the flag off answers `:next` for every method, so the disabled
  endpoints are indistinguishable from any other unserved path.
  """
  @spec serve(Plug.Conn.t(), map()) :: Plug.Conn.t() | :next
  def serve(%{method: "GET", path_info: @card_schema_path} = conn, %{serve_schemas: true}) do
    serve_schema(conn, agent_card_schema())
  end

  def serve(%{method: "GET", path_info: @skills_schema_path} = conn, %{serve_schemas: true} = opts) do
    serve_schema(conn, skills_schema(opts.schema_index))
  end

  def serve(%{path_info: path} = conn, %{serve_schemas: true})
      when path in [@card_schema_path, @skills_schema_path] do
    conn
    |> Plug.Conn.put_resp_header("allow", "GET")
    |> Plug.Conn.send_resp(405, "Method Not Allowed")
  end

  def serve(_conn, _opts), do: :next

  # -- GET /.well-known/agent-card.schema.json --------------------------------

  # Hand-authored from the v1.0 proto (priv/proto/a2a.proto). Member names are
  # the protojson wire names the codec emits; the proto field numbers and line
  # numbers are cited per $def. `additionalProperties: false` everywhere, so a
  # codec that grows a member the proto does not define fails this schema.
  @agent_card_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "title" => "A2A v1.0 AgentCard",
    "description" =>
      "JSON Schema of the A2A v1.0 AgentCard wire shape served by ash_a2a " <>
        "(hand-authored from priv/proto/a2a.proto, message AgentCard, fields 1-14).",
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "version" => %{"type" => "string"},
      "skills" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/AgentSkill"}},
      "capabilities" => %{"$ref" => "#/$defs/AgentCapabilities"},
      "defaultInputModes" => %{"type" => "array", "items" => %{"type" => "string"}},
      "defaultOutputModes" => %{"type" => "array", "items" => %{"type" => "string"}},
      "supportedInterfaces" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/AgentInterface"}
      },
      "provider" => %{"$ref" => "#/$defs/AgentProvider"},
      "documentationUrl" => %{"type" => "string"},
      "iconUrl" => %{"type" => "string"},
      "securitySchemes" => %{
        "type" => "object",
        "additionalProperties" => %{"$ref" => "#/$defs/SecurityScheme"}
      },
      "securityRequirements" => %{
        "type" => "array",
        "items" => %{"$ref" => "#/$defs/SecurityRequirement"}
      },
      "signatures" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/AgentCardSignature"}}
    },
    "required" => [
      "name",
      "description",
      "version",
      "skills",
      "capabilities",
      "defaultInputModes",
      "defaultOutputModes",
      "supportedInterfaces"
    ],
    "additionalProperties" => false,
    "$defs" => %{
      "AgentInterface" => %{
        "description" => "a2a.proto message AgentInterface (lines 360-382), fields 1/2/4 REQUIRED",
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "protocolBinding" => %{"type" => "string"},
          "protocolVersion" => %{"type" => "string"},
          "tenant" => %{"type" => "string"}
        },
        "required" => ["url", "protocolBinding", "protocolVersion"],
        "additionalProperties" => false
      },
      "AgentSkill" => %{
        "description" => "a2a.proto message AgentSkill (lines 460-478), fields 1-4 REQUIRED",
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string"},
          "name" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "examples" => %{"type" => "array", "items" => %{"type" => "string"}},
          "inputModes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "outputModes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "securityRequirements" => %{
            "type" => "array",
            "items" => %{"$ref" => "#/$defs/SecurityRequirement"}
          }
        },
        "required" => ["id", "name", "description", "tags"],
        "additionalProperties" => false
      },
      "AgentProvider" => %{
        "description" => "a2a.proto message AgentProvider (lines 426-433), fields 1/2 REQUIRED",
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "organization" => %{"type" => "string"}
        },
        "required" => ["url", "organization"],
        "additionalProperties" => false
      },
      "AgentCapabilities" => %{
        "description" => "a2a.proto message AgentCapabilities (lines 436-447); all members optional",
        "type" => "object",
        "properties" => %{
          "streaming" => %{"type" => "boolean"},
          "pushNotifications" => %{"type" => "boolean"},
          "extendedAgentCard" => %{"type" => "boolean"},
          "extensions" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/AgentExtension"}}
        },
        "additionalProperties" => false
      },
      "AgentExtension" => %{
        "description" => "a2a.proto message AgentExtension (lines 448-459), field 1 (uri) required",
        "type" => "object",
        "properties" => %{
          "uri" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "required" => %{"type" => "boolean"},
          "params" => %{"type" => "object"}
        },
        "required" => ["uri"],
        "additionalProperties" => false
      },
      "AgentCardSignature" => %{
        "description" =>
          "a2a.proto message AgentCardSignature (lines 481-497), fields 1/2 REQUIRED",
        "type" => "object",
        "properties" => %{
          "protected" => %{"type" => "string"},
          "signature" => %{"type" => "string"},
          "header" => %{"type" => "object"}
        },
        "required" => ["protected", "signature"],
        "additionalProperties" => false
      },
      "SecurityScheme" => %{
        "description" =>
          "a2a.proto message SecurityScheme (lines 528+, oneof api_key/http_auth/oauth2/" <>
            "openid_connect/mutual_tls); the discriminating member is required",
        "type" => "object",
        "anyOf" => [
          %{"required" => ["apiKey"]},
          %{"required" => ["http"]},
          %{"required" => ["oauth2"]},
          %{"required" => ["googleOidc"]},
          %{"required" => ["openIdConnect"]},
          %{"required" => ["mtls"]}
        ]
      },
      "SecurityRequirement" => %{
        "description" =>
          "a2a.proto message SecurityRequirement: a map of scheme name to scopes; " <>
            "the codec emits the protojson shape %{'schemes' => %{name => %{'list' => _}}}",
        "type" => "object",
        "properties" => %{
          "schemes" => %{"type" => "object"}
        }
      },
      "TaskState" => %{
        "description" =>
          "a2a.proto enum TaskState (lines 211-233): the nine protojson enum " <>
            "values the codec emits on the tasks surface",
        "type" => "string",
        "enum" => [
          "TASK_STATE_UNSPECIFIED",
          "TASK_STATE_SUBMITTED",
          "TASK_STATE_WORKING",
          "TASK_STATE_COMPLETED",
          "TASK_STATE_FAILED",
          "TASK_STATE_CANCELED",
          "TASK_STATE_INPUT_REQUIRED",
          "TASK_STATE_REJECTED",
          "TASK_STATE_AUTH_REQUIRED"
        ]
      }
    }
  }

  @doc """
  The static JSON Schema (Draft 2020-12) of the A2A v1.0 AgentCard wire
  shape. A compile-time literal map: no agent input touches it.
  """
  @spec agent_card_schema() :: %{optional(String.t()) => term()}
  def agent_card_schema, do: @agent_card_schema

  # -- GET /.well-known/skills.schema.json --------------------------------------

  @doc """
  The live per-skill schema document: `AshA2A.Schema.for_skill/2` outputs for
  every skill in the given capability index, keyed by skill id, plus the
  typed `omitted` list for skills whose action carries an argument type the
  projection cannot represent (same convention as
  `AshA2A.Protocol.Extensions.Schema`).
  """
  @spec skills_schema(
          module() | (-> [AshA2A.Skill.t()]) | [AshA2A.Skill.t()]
        ) :: %{optional(String.t()) => term()}
  def skills_schema(schema_index) do
    {schemas, omitted} =
      schema_index
      |> skills()
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce({%{}, []}, fn skill, {schemas, omitted} ->
        case project_skill(skill) do
          {:ok, schema} ->
            {Map.put(schemas, skill.id, schema), omitted}

          {:error, reason} ->
            {schemas, [omitted_entry(skill, reason) | omitted]}
        end
      end)

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "A2A Agent Skills",
      "description" =>
        "Per-skill JSON Schema (Draft 2020-12) for skill input arguments, generated " <>
          "live from the serving agent's compiled capability index and keyed by skill id " <>
          "(the same id the agent card's skills[].id uses); skills with unserializable " <>
          "argument types are listed under \"omitted\" with a typed reason.",
      "skills" => schemas,
      "omitted" => Enum.reverse(omitted)
    }
  end

  # A skill whose resource is nil (a raw `%AshA2A.Skill{}` the host supplied
  # without one) cannot be projected -- `AshA2A.Schema.for_skill/2` needs the
  # real Ash action to introspect -- so it is honestly omitted with a typed
  # reason rather than crashing the endpoint.
  defp project_skill(%AshA2A.Skill{resource: nil} = skill),
    do: {:error, {:no_resource, skill.id}}

  defp project_skill(skill), do: Schema.for_skill(skill, skill.resource)

  defp omitted_entry(skill, {:unserializable_type, type}),
    do: %{"skill" => skill.id, "reason" => "unserializable_type", "type" => inspect(type)}

  defp omitted_entry(skill, {:no_resource, _id}),
    do: %{"skill" => skill.id, "reason" => "no_resource"}

  defp skills(index) when is_function(index, 0), do: skills(index.())
  defp skills(index) when is_list(index), do: index

  defp skills(index) when is_atom(index) do
    case AshA2A.Info.capability_index_result(index) do
      {:ok, skills} -> skills
      {:error, :not_compiled} -> []
    end
  end

  defp serve_schema(conn, schema) do
    body = Jason.encode!(schema, pretty: false)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "max-age=60")
    |> Plug.Conn.send_resp(200, body)
  end
end
