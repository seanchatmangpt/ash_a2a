defmodule AshA2A.Protocol.JSON do
  @moduledoc """
  Codec for converting between Elixir structs and the A2A v1.0 camelCase JSON wire format.

  Produces intermediate maps (not JSON strings) suitable for composing with
  JSON-RPC envelopes. Use `Jason.encode!/1` on the result when you need a string.

  Dialect policy: **v1.0 is the primary encode target; the legacy v0.3 wire
  format is decode-only tolerance** (never emitted). Encoding emits the v1.0
  flat shape — no `kind` discriminator, flat `Part` with
  `text`/`data`/`raw`/`url` + `mediaType`/`filename`. Streaming events encode
  flat (`taskId` + `status`/`artifact`) and are wrapped for the wire by
  `encode_stream_response/1` as a single-member v1.0 `StreamResponse`
  (`{"statusUpdate": ...}` / `{"artifactUpdate": ...}`); no `kind` key and no
  `final` boolean is ever emitted — finality is carried by a terminal status
  state. Decoding accepts both the v1.0 wrapper and the legacy v0.3 forms
  (bare task/status/artifact frames, `kind`-tagged `"status-update"`/
  `"artifact-update"` events, `"final": true`).

  ## Encoding

      iex> part = AshA2A.Protocol.Part.Text.new("hello")
      iex> {:ok, map} = AshA2A.Protocol.JSON.encode(part)
      iex> map
      %{"text" => "hello"}

  ## Decoding

      iex> {:ok, part} = AshA2A.Protocol.JSON.decode(%{"text" => "hello"}, :part)
      iex> part
      %AshA2A.Protocol.Part.Text{text: "hello", metadata: %{}}
  """

  # v1 protojson emission vocabulary: every value is a real `lf.a2a.v1`
  # TaskState enum member. The internal `:unknown` atom (the indeterminate
  # state) maps to the proto3 zero value TASK_STATE_UNSPECIFIED on the wire —
  # the proto has no TASK_STATE_UNKNOWN (Z16-F1).
  @state_to_string %{
    submitted: "TASK_STATE_SUBMITTED",
    working: "TASK_STATE_WORKING",
    input_required: "TASK_STATE_INPUT_REQUIRED",
    completed: "TASK_STATE_COMPLETED",
    canceled: "TASK_STATE_CANCELED",
    failed: "TASK_STATE_FAILED",
    rejected: "TASK_STATE_REJECTED",
    auth_required: "TASK_STATE_AUTH_REQUIRED",
    unknown: "TASK_STATE_UNSPECIFIED"
  }

  # Auto-derive canonical inverse, then merge legacy aliases
  @string_to_state @state_to_string
                   |> Map.new(fn {k, v} -> {v, k} end)
                   |> Map.merge(%{
                     # Legacy lowercase format
                     "submitted" => :submitted,
                     "working" => :working,
                     "input-required" => :input_required,
                     "completed" => :completed,
                     "canceled" => :canceled,
                     "failed" => :failed,
                     "rejected" => :rejected,
                     "auth-required" => :auth_required,
                     "unknown" => :unknown,
                     # v0.3 spelling of the indeterminate state: accepted on
                     # decode (→ :unknown) but never emitted (Z16-F1).
                     "TASK_STATE_UNKNOWN" => :unknown
                   })

  # v1.0 dropped `final` from TaskStatusUpdateEvent: a stream runs until the
  # task reaches a terminal or interrupted state, then closes. These are the
  # states that end one, used to reconstruct the flag on decode.
  @final_states [:completed, :canceled, :failed, :rejected, :input_required, :auth_required]

  # v0.3 wire format: ROLE_* prefixed enum values
  @role_to_string %{user: "ROLE_USER", agent: "ROLE_AGENT"}

  @string_to_role @role_to_string
                  |> Map.new(fn {k, v} -> {v, k} end)
                  |> Map.merge(%{
                    # Legacy lowercase format
                    "user" => :user,
                    "agent" => :agent
                  })

  @doc """
  Returns the list of valid v0.3 wire-format state strings.
  """
  @spec valid_state_strings() :: [String.t()]
  def valid_state_strings, do: Map.values(@state_to_string)

  @doc """
  Decodes a wire-format state string to an atom.

  Accepts both v0.3 (`"TASK_STATE_WORKING"`) and legacy (`"working"`)
  formats.
  """
  @spec decode_state(String.t()) :: {:ok, atom()} | {:error, {:invalid_state, String.t()}}
  def decode_state(str) when is_map_key(@string_to_state, str) do
    {:ok, @string_to_state[str]}
  end

  def decode_state(str), do: {:error, {:invalid_state, str}}

  # -------------------------------------------------------------------
  # Encoding
  # -------------------------------------------------------------------

  @type encode_result :: {:ok, map()} | {:error, term()}

  @doc """
  Encodes an Elixir struct to a JSON-ready map.

  Returns `{:ok, map}` on success or `{:error, reason}` on failure.
  Optional `nil` fields and empty collections are omitted from the output.
  """
  @spec encode(struct()) :: encode_result()
  def encode(%AshA2A.Protocol.Task{} = task) do
    {:ok, status} = encode(task.status)

    # contextId is REQUIRED on the wire (v0.3 TCK + protobuf default "") —
    # emit an empty string when the struct field is nil.
    map =
      %{"id" => task.id, "contextId" => task.context_id || "", "status" => status}
      |> put_unless_empty("history", encode_list(task.history))
      |> put_unless_empty("artifacts", encode_list(task.artifacts))
      |> put_unless_empty("metadata", task.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Task.Status{} = status) do
    map =
      %{"state" => encode_state(status.state)}
      |> put_unless_nil_nested("message", status.message)
      |> put_unless_nil("timestamp", encode_timestamp(status.timestamp))

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Message{} = msg) do
    map =
      %{
        "role" => Map.fetch!(@role_to_string, msg.role),
        "parts" => encode_list(msg.parts)
      }
      |> put_unless_nil("messageId", msg.message_id)
      |> put_unless_nil("taskId", msg.task_id)
      |> put_unless_nil("contextId", msg.context_id)
      |> put_unless_empty("referenceTaskIds", msg.reference_task_ids)
      |> put_unless_empty("metadata", msg.metadata)
      |> put_unless_empty("extensions", msg.extensions)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Artifact{} = artifact) do
    map =
      %{"parts" => encode_list(artifact.parts)}
      |> put_unless_nil("artifactId", artifact.artifact_id)
      |> put_unless_nil("name", artifact.name)
      |> put_unless_nil("description", artifact.description)
      |> put_unless_empty("extensions", artifact.extensions)
      |> put_unless_empty("metadata", artifact.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Part.Text{} = part) do
    map =
      %{"text" => part.text}
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Part.File{file: %AshA2A.Protocol.FileContent{} = fc} = part) do
    map =
      %{}
      |> put_unless_nil("filename", fc.name)
      |> put_unless_nil("mediaType", fc.mime_type)
      |> put_unless_nil("url", fc.uri)
      |> put_unless_nil("raw", encode_bytes(fc.bytes))
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Part.Data{} = part) do
    map =
      %{"data" => part.data}
      |> put_unless_empty("metadata", part.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.FileContent{} = fc) do
    map =
      %{}
      |> put_unless_nil("name", fc.name)
      |> put_unless_nil("mimeType", fc.mime_type)
      |> put_unless_nil("uri", fc.uri)
      |> put_unless_nil("bytes", encode_bytes(fc.bytes))

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Event.StatusUpdate{} = event) do
    {:ok, status} = encode(event.status)

    map =
      %{"taskId" => event.task_id, "status" => status}
      |> put_unless_nil("contextId", event.context_id)
      |> put_unless_empty("metadata", event.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.Event.ArtifactUpdate{} = event) do
    {:ok, artifact} = encode(event.artifact)

    map =
      %{"taskId" => event.task_id, "artifact" => artifact}
      |> put_unless_nil("contextId", event.context_id)
      |> put_unless_nil("append", event.append)
      |> put_unless_nil("lastChunk", event.last_chunk)
      |> put_unless_empty("metadata", event.metadata)

    {:ok, map}
  end

  def encode(%AshA2A.Protocol.PushNotificationConfig{} = config) do
    map =
      %{"url" => config.url}
      |> put_unless_nil("id", config.id)
      |> put_unless_nil("taskId", config.task_id)
      |> put_unless_nil("token", config.token)
      |> put_unless_nil("authentication", encode_push_authentication(config.authentication))

    {:ok, map}
  end

  def encode(%{__struct__: mod}) do
    {:error, {:unsupported_type, mod}}
  end

  @doc """
  Encodes a streaming event into the v1.0 `StreamResponse` wrapper.

  Streaming operations and push notification payloads carry exactly one of
  `task`, `message`, `statusUpdate` or `artifactUpdate`. The wrapper key is
  the discriminator, which is why the wrapped objects carry no `kind` of
  their own — the schema rejects unknown properties at both levels.
  """
  @spec encode_stream_response(struct()) :: encode_result()
  def encode_stream_response(%AshA2A.Protocol.Task{} = task), do: wrap_stream_response("task", task)

  def encode_stream_response(%AshA2A.Protocol.Message{} = message),
    do: wrap_stream_response("message", message)

  def encode_stream_response(%AshA2A.Protocol.Event.StatusUpdate{} = event),
    do: wrap_stream_response("statusUpdate", event)

  def encode_stream_response(%AshA2A.Protocol.Event.ArtifactUpdate{} = event),
    do: wrap_stream_response("artifactUpdate", event)

  def encode_stream_response(%{__struct__: mod}), do: {:error, {:unsupported_type, mod}}

  defp wrap_stream_response(key, struct) do
    with {:ok, encoded} <- encode(struct), do: {:ok, %{key => encoded}}
  end

  @doc """
  Encodes an Elixir struct to a JSON-ready map, raising on failure.
  """
  @spec encode!(struct()) :: map()
  def encode!(struct) do
    case encode(struct) do
      {:ok, map} -> map
      {:error, reason} -> raise ArgumentError, "encode failed: #{inspect(reason)}"
    end
  end

  @doc """
  Encodes an agent card into the AgentCard JSON format.

  Accepts either a plain map (as returned by `AshA2A.Protocol.Agent.agent_card/0`) or a
  fully-populated `%AshA2A.Protocol.AgentCard{}` struct. When a struct is passed, fields
  like `capabilities`, `provider`, `documentation_url`, etc. are read from
  the struct and used as defaults. Options in `opts` always take precedence
  over struct fields.

  In v1.0 the top-level `url` and `protocolVersion` fields are gone from the
  wire format — both are per-interface. The `:url` option is still required
  because it seeds the default `supportedInterfaces` entry; pass
  `:supported_interfaces` directly to override.

  ## Options

  All options override the corresponding struct field when a
  `%AshA2A.Protocol.AgentCard{}` is passed as `card`.

  - `:url` — agent endpoint URL, used as the default `supportedInterfaces[0].url`
  - `:capabilities` — `AgentCapabilities` map (default: `%{}`)
  - `:default_input_modes` — list of MIME types (default: `["text/plain"]`)
  - `:default_output_modes` — list of MIME types (default: `["text/plain"]`)
  - `:provider` — `%{organization: ..., url: ...}` map
  - `:documentation_url` — URL string
  - `:icon_url` — URL string
  - `:supported_interfaces` — list of `%{url: ..., protocol_binding: ...,
    protocol_version: ...}` maps. Defaults to a single JSON-RPC interface
    derived from `:url`.
  - `:security_schemes` — `%{name => %SecurityScheme.X{}}` map
  - `:security` — list of `%{name => scopes}` maps (OpenAPI-style). Encoded as
    the v1.0 `securityRequirements` wire member (deprecated v0.3 spelling
    `security` is accepted on decode but never emitted).
  - `:signatures` — list of JWS signature maps (each `%{"protected" => ...,
    "signature" => ..., "header" => ...}`)

  NEVER emitted: a top-level `preferredTransport` member. The v1.0
  `AgentCard` proto message (priv/a2a_v1_spec_corpus/a2a.proto:362,
  fields 1-14) has no such field — transport preference IS positional,
  carried by `supportedInterfaces[0]` ("Ordered list of supported
  interfaces. The first entry is preferred.", a2a.proto:370), and no
  example in priv/a2a_v1_spec_corpus/v1_spec_examples.json carries the
  member. The struct's `preferred_transport` is a struct-only convenience
  field and is deliberately dropped at the wire boundary (pinned by
  AshA2A.V1WirePropertiesTest and the capability-index card-shape court).
  """
  @spec encode_agent_card(AshA2A.Protocol.AgentCard.t() | AshA2A.Protocol.Agent.card(), keyword()) :: map()
  def encode_agent_card(card, opts \\ []) do
    url = Keyword.fetch!(opts, :url)
    capabilities = card_field(opts, card, :capabilities, %{})
    input_modes = card_field(opts, card, :default_input_modes, ["text/plain"])
    output_modes = card_field(opts, card, :default_output_modes, ["text/plain"])

    interfaces =
      Keyword.get(opts, :supported_interfaces) ||
        non_empty(Map.get(card, :supported_interfaces)) ||
        [%{url: url, protocol_binding: "JSONRPC", protocol_version: AshA2A.Protocol.Version.protocol_version()}]

    security_schemes = card_field(opts, card, :security_schemes, %{})
    security = card_field(opts, card, :security, [])

    skills =
      Enum.map(card.skills, fn skill ->
        %{
          "id" => skill.id,
          "name" => skill.name,
          "description" => skill.description,
          "tags" => skill.tags
        }
        # Spec AgentSkill fields 6/7: per-skill mode overrides are OPTIONAL.
        # Emitted only when non-nil -- a skill without them inherits the
        # card-level defaultInputModes/defaultOutputModes, and the wire
        # member's absence is exactly that inheritance signal.
        |> put_unless_nil("inputModes", Map.get(skill, :input_modes))
        |> put_unless_nil("outputModes", Map.get(skill, :output_modes))
        # Spec AgentSkill field 8: per-skill security requirements are
        # OPTIONAL (lf.a2a.v1 AgentSkill.security_requirements = 8, protojson
        # name "securityRequirements" -- priv/a2a_v1_spec_corpus/a2a.proto:452).
        # Emitted only when set (nil/[] dropped): a skill without them inherits
        # the card-level securityRequirements, and the member's absence is
        # exactly that inheritance signal -- same as per-skill modes fields
        # 6/7 above. The struct stores the flat %{scheme-name => [scopes]}
        # shape, so the entries normalize through the same encoder as the
        # card-level member.
        |> put_unless_empty(
          "securityRequirements",
          encode_security_requirements(Map.get(skill, :security_requirements) || [])
        )
      end)

    caps = encode_capabilities(capabilities)

    map =
      %{
        "name" => card.name,
        "description" => card.description,
        "version" => card.version,
        "skills" => skills,
        "capabilities" => caps,
        "defaultInputModes" => input_modes,
        "defaultOutputModes" => output_modes,
        "supportedInterfaces" => encode_interfaces(interfaces)
      }
      |> put_unless_nil("provider", encode_provider(card_field(opts, card, :provider, nil)))
      |> put_unless_nil("documentationUrl", card_field(opts, card, :documentation_url, nil))
      |> put_unless_nil("iconUrl", card_field(opts, card, :icon_url, nil))
      |> put_unless_empty("securitySchemes", encode_security_schemes(security_schemes))
      # A2A v1.0 renamed the v0.3 card member `security` to `securityRequirements`
      # (lf.a2a.v1 AgentCard.security_requirements = 9, protojson name
      # "securityRequirements" -- priv/a2a_v1_spec_corpus/a2a.proto:384; the vendored
      # v1 spec example v1_spec_examples.json examples[1].wire carries
      # "securityRequirements"). DEPRECATED: the v0.3 spelling "security" is never
      # emitted; decode still accepts it for legacy peers.
      |> put_unless_empty("securityRequirements", encode_security_requirements(security))
      # No "preferredTransport" is ever projected: the v1.0 AgentCard proto
      # message has no such field (priv/a2a_v1_spec_corpus/a2a.proto:362,
      # fields 1-14); preference is positional via supportedInterfaces[0]
      # (a2a.proto:370). The struct's preferred_transport is struct-only and
      # intentionally absent from the wire.
      |> put_unless_empty("signatures", card_field(opts, card, :signatures, []))

    map
  end

  # Resolves a field from caller opts first (explicit override), then from the
  # card struct/map, then the given default. Lets callers pass a fully-populated
  # %AshA2A.Protocol.AgentCard{} OR supply fields via opts (backward compatible).
  defp card_field(opts, card, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.get(card, key) do
          nil -> default
          value -> value
        end
    end
  end

  defp non_empty([]), do: nil
  defp non_empty(value), do: value

  @doc """
  Decodes a JSON map into an `%AshA2A.Protocol.AgentCard{}` struct.

  Returns `{:ok, agent_card}` on success or `{:error, reason}` on failure.

  ## Example

      iex> map = %{
      ...>   "name" => "test",
      ...>   "description" => "A test agent",
      ...>   "url" => "https://example.com",
      ...>   "version" => "1.0.0",
      ...>   "skills" => [
      ...>     %{"id" => "s1", "name" => "Skill", "description" => "Does things", "tags" => []}
      ...>   ]
      ...> }
      iex> {:ok, card} = AshA2A.Protocol.JSON.decode_agent_card(map)
      iex> card.name
      "test"
  """
  @spec decode_agent_card(map()) :: {:ok, AshA2A.Protocol.AgentCard.t()} | {:error, term()}
  def decode_agent_card(map) when is_map(map) do
    with {:ok, name} <- require_field(map, "name"),
         {:ok, description} <- require_field(map, "description"),
         {:ok, version} <- require_field(map, "version"),
         {:ok, skills_list} <- require_field(map, "skills"),
         {:ok, skills} <- decode_card_skills(skills_list) do
      interfaces = decode_card_interfaces(Map.get(map, "supportedInterfaces", []))
      url = Map.get(map, "url") || preferred_interface_url(interfaces)

      {:ok,
       %AshA2A.Protocol.AgentCard{
         name: name,
         description: description,
         url: url,
         version: version,
         skills: skills,
         capabilities: decode_card_capabilities(Map.get(map, "capabilities", %{})),
         default_input_modes: Map.get(map, "defaultInputModes", ["text/plain"]),
         default_output_modes: Map.get(map, "defaultOutputModes", ["text/plain"]),
         provider: decode_card_provider(Map.get(map, "provider")),
         documentation_url: Map.get(map, "documentationUrl"),
         icon_url: Map.get(map, "iconUrl"),
         protocol_version: Map.get(map, "protocolVersion"),
         # Deliberately NOT read: no "preferredTransport" lookup. The v1.0
         # AgentCard proto message (priv/a2a_v1_spec_corpus/a2a.proto:362,
         # fields 1-14) defines no such member -- transport preference is
         # positional, `supported_interfaces` field 3 ("The first entry is
         # preferred", a2a.proto:370) -- so the struct-only
         # `preferred_transport` convenience field stays nil after decode
         # even if a foreign/legacy peer includes the key (v0.3-era cards;
         # no member in v1_spec_examples.json carries it).
         supported_interfaces: interfaces,
         security_schemes: decode_card_security_schemes(Map.get(map, "securitySchemes", %{})),
         # Reads BOTH spellings: v1.0 "securityRequirements" (preferred) and the
         # deprecated v0.3 "security" key, normalizing to the struct's flat
         # %{name => scopes} shape.
         security:
           decode_card_security(
             Map.get(map, "securityRequirements") || Map.get(map, "security", [])
           ),
         signatures: Map.get(map, "signatures", [])
       }}
    end
  end

  defp preferred_interface_url([%{url: url} | _]) when is_binary(url), do: url
  defp preferred_interface_url(_), do: nil

  # -------------------------------------------------------------------
  # Decoding
  # -------------------------------------------------------------------

  @type decode_type ::
          :task
          | :status
          | :message
          | :artifact
          | :part
          | :file_content
          | :event
          | :status_update_event
          | :artifact_update_event
          | :push_notification_config

  @doc """
  Decodes a JSON map into an Elixir struct of the given type.

  Returns `{:ok, struct}` on success or `{:error, reason}` on failure.

  The `:part` type dispatches on the `"kind"` field, or infers the type
  from content fields (`"text"`, `"file"`, `"data"`) when `"kind"` is
  absent (v0.3 format). The `:event` type dispatches on the v1.0
  `StreamResponse` wrapper key — `"task"`, `"message"`, `"statusUpdate"` or
  `"artifactUpdate"` — falling back to the v0.3 `"kind"` discriminator.
  """
  @spec decode(map(), decode_type()) :: {:ok, struct()} | {:error, term()}
  def decode(map, :task) do
    with {:ok, id} <- require_field(map, "id"),
         {:ok, status_map} <- require_field(map, "status"),
         {:ok, status} <- decode(status_map, :status),
         {:ok, history} <- decode_list(Map.get(map, "history", []), :message),
         {:ok, artifacts} <- decode_list(Map.get(map, "artifacts", []), :artifact) do
      {:ok,
       %AshA2A.Protocol.Task{
         id: id,
         context_id: Map.get(map, "contextId"),
         status: status,
         history: history,
         artifacts: artifacts,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :status) do
    with {:ok, state_str} <- require_field(map, "state"),
         {:ok, state} <- decode_state(state_str),
         {:ok, message} <- decode_optional(Map.get(map, "message"), :message),
         {:ok, timestamp} <- decode_timestamp(Map.get(map, "timestamp")) do
      {:ok,
       %AshA2A.Protocol.Task.Status{
         state: state,
         message: message,
         timestamp: timestamp
       }}
    end
  end

  def decode(map, :message) do
    with {:ok, message_id} <- require_field(map, "messageId"),
         {:ok, role_str} <- require_field(map, "role"),
         {:ok, role} <- decode_role(role_str),
         {:ok, parts_list} <- require_field(map, "parts"),
         :ok <- require_non_empty(parts_list, "parts"),
         {:ok, parts} <- decode_list(parts_list, :part) do
      {:ok,
       %AshA2A.Protocol.Message{
         message_id: message_id,
         role: role,
         parts: parts,
         task_id: Map.get(map, "taskId"),
         context_id: Map.get(map, "contextId"),
         reference_task_ids: Map.get(map, "referenceTaskIds", []),
         metadata: Map.get(map, "metadata", %{}),
         extensions: Map.get(map, "extensions", %{})
       }}
    end
  end

  def decode(map, :artifact) do
    with {:ok, parts_list} <- require_field(map, "parts"),
         {:ok, parts} <- decode_list(parts_list, :part) do
      {:ok,
       %AshA2A.Protocol.Artifact{
         artifact_id: Map.get(map, "artifactId"),
         name: Map.get(map, "name"),
         description: Map.get(map, "description"),
         parts: parts,
         extensions: Map.get(map, "extensions", []),
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :part) do
    case Map.get(map, "kind") do
      "text" -> decode_text_part(map)
      "file" -> decode_file_part(map)
      "data" -> decode_data_part(map)
      nil -> infer_part_type(map)
      other -> {:error, {:unknown_kind, other}}
    end
  end

  def decode(map, :file_content) do
    bytes_str = Map.get(map, "bytes") || Map.get(map, "fileWithBytes")

    with {:ok, bytes} <- decode_base64(bytes_str) do
      {:ok,
       %AshA2A.Protocol.FileContent{
         name: Map.get(map, "name"),
         mime_type: Map.get(map, "mimeType") || Map.get(map, "mediaType"),
         bytes: bytes,
         uri: Map.get(map, "uri") || Map.get(map, "fileWithUri")
       }}
    end
  end

  def decode(map, :event) do
    case map do
      %{"task" => inner} when is_map(inner) -> decode(inner, :task)
      %{"message" => inner} when is_map(inner) -> decode(inner, :message)
      %{"statusUpdate" => inner} when is_map(inner) -> decode(inner, :status_update_event)
      %{"artifactUpdate" => inner} when is_map(inner) -> decode(inner, :artifact_update_event)
      # The schema's patternProperties accept the snake_case spelling too.
      %{"status_update" => inner} when is_map(inner) -> decode(inner, :status_update_event)
      %{"artifact_update" => inner} when is_map(inner) -> decode(inner, :artifact_update_event)
      _ -> decode_event_by_kind(map)
    end
  end

  def decode(map, :status_update_event) do
    with {:ok, task_id} <- require_field(map, "taskId"),
         {:ok, status_map} <- require_field(map, "status"),
         {:ok, status} <- decode(status_map, :status) do
      {:ok,
       %AshA2A.Protocol.Event.StatusUpdate{
         task_id: task_id,
         context_id: Map.get(map, "contextId"),
         status: status,
         final: Map.get(map, "final", status.state in @final_states),
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :artifact_update_event) do
    with {:ok, task_id} <- require_field(map, "taskId"),
         {:ok, artifact_map} <- require_field(map, "artifact"),
         {:ok, artifact} <- decode(artifact_map, :artifact) do
      {:ok,
       %AshA2A.Protocol.Event.ArtifactUpdate{
         task_id: task_id,
         context_id: Map.get(map, "contextId"),
         artifact: artifact,
         append: Map.get(map, "append"),
         last_chunk: Map.get(map, "lastChunk"),
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  def decode(map, :push_notification_config) do
    with {:ok, url} <- require_field(map, "url") do
      {:ok,
       %AshA2A.Protocol.PushNotificationConfig{
         id: Map.get(map, "id"),
         task_id: Map.get(map, "taskId") || Map.get(map, "task_id"),
         url: url,
         token: Map.get(map, "token"),
         authentication: decode_push_authentication(Map.get(map, "authentication"))
       }}
    end
  end

  @doc """
  Decodes a JSON map into an Elixir struct, raising on failure.
  """
  @spec decode!(map(), decode_type()) :: struct()
  def decode!(map, type) do
    case decode(map, type) do
      {:ok, struct} -> struct
      {:error, reason} -> raise ArgumentError, "decode failed: #{inspect(reason)}"
    end
  end

  # -------------------------------------------------------------------
  # Private — Encoding helpers
  # -------------------------------------------------------------------

  defp encode_state(state) do
    Map.fetch!(@state_to_string, state)
  end

  defp encode_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601(:extended)
    |> String.replace_suffix("+00:00", "Z")
  end

  defp encode_timestamp(nil), do: nil

  defp encode_bytes(nil), do: nil
  defp encode_bytes(bytes) when is_binary(bytes), do: Base.encode64(bytes)

  defp encode_list(items) do
    Enum.map(items, fn item ->
      {:ok, encoded} = encode(item)
      encoded
    end)
  end

  defp encode_capabilities(caps) when is_map(caps) do
    # v1 dropped state_transition_history from AgentCapabilities (Z16-F3):
    # the struct key may still be present internally but is never emitted.
    caps
    |> encode_known_keys([
      {"streaming", :streaming},
      {"pushNotifications", :push_notifications},
      {"extendedAgentCard", :extended_agent_card}
    ])
    |> put_unless_empty("extensions", encode_agent_extensions(Map.get(caps, :extensions, [])))
  end

  defp encode_agent_extensions(extensions) do
    extensions |> List.wrap() |> Enum.map(&encode_agent_extension/1)
  end

  @doc false
  def encode_agent_extension(%AshA2A.Protocol.AgentExtension{} = ext) do
    %{"uri" => ext.uri, "required" => ext.required}
    |> put_unless_nil("description", ext.description)
    |> put_unless_nil("params", ext.params)
  end

  # Plain-map extensions (builder opts / attach paths) encode identically —
  # the struct and the wire shape share the four keys.
  def encode_agent_extension(%{} = ext) do
    %{"uri" => Map.get(ext, :uri) || Map.get(ext, "uri"),
      "required" => Map.get(ext, :required) || Map.get(ext, "required") || false}
    |> put_unless_nil("description", Map.get(ext, :description) || Map.get(ext, "description"))
    |> put_unless_nil("params", Map.get(ext, :params) || Map.get(ext, "params"))
  end

  defp encode_interfaces(interfaces) when is_list(interfaces) do
    mappings = [
      {"url", :url},
      {"protocolBinding", :protocol_binding},
      {"protocolVersion", :protocol_version}
    ]

    Enum.map(interfaces, &encode_known_keys(&1, mappings))
  end

  defp encode_provider(nil), do: nil

  defp encode_provider(provider) when is_map(provider) do
    encode_known_keys(provider, [
      {"organization", :organization},
      {"url", :url}
    ])
  end

  # Card security entries are stored flat (%{scheme-name => scopes}) in the
  # struct's :security field; the v1.0 wire shape is the protojson rendering of
  # SecurityRequirement: %{"schemes" => %{name => %{"list" => scopes}}}.
  defp encode_security_requirements(reqs) when is_list(reqs) do
    Enum.map(reqs, fn
      # Already wire-shaped (pre-encoded) entries pass through untouched.
      %{"schemes" => _} = wire_shaped ->
        wire_shaped

      flat when is_map(flat) ->
        %{"schemes" => Map.new(flat, fn {name, scopes} -> {name, %{"list" => scopes}} end)}
    end)
  end

  defp encode_security_schemes(schemes) when map_size(schemes) == 0, do: %{}

  defp encode_security_schemes(schemes) when is_map(schemes) do
    Map.new(schemes, fn {name, scheme} ->
      {name, encode_security_scheme(scheme)}
    end)
  end

  # The v1 proto field is `location` (Z16-F4); the struct key remains `:in`
  # (v0.3 spelling), mapped to the proto field at encode.
  defp encode_security_scheme(%AshA2A.Protocol.SecurityScheme.APIKey{} = s) do
    %{"apiKeySecurityScheme" => %{"name" => s.name, "location" => s.in}}
  end

  defp encode_security_scheme(%AshA2A.Protocol.SecurityScheme.HTTPAuth{} = s) do
    %{"httpAuthSecurityScheme" => %{"scheme" => s.scheme}}
  end

  defp encode_security_scheme(%AshA2A.Protocol.SecurityScheme.OAuth2{} = s) do
    inner = %{"flows" => s.flows}

    inner =
      if s.oauth2_metadata_url,
        do: Map.put(inner, "oauth2MetadataUrl", s.oauth2_metadata_url),
        else: inner

    %{"oauth2SecurityScheme" => inner}
  end

  defp encode_security_scheme(%AshA2A.Protocol.SecurityScheme.OpenIDConnect{} = s) do
    %{
      "openIdConnectSecurityScheme" => %{
        "openIdConnectUrl" => s.open_id_connect_url
      }
    }
  end

  defp encode_security_scheme(%AshA2A.Protocol.SecurityScheme.MutualTLS{}) do
    %{"mtlsSecurityScheme" => %{}}
  end

  @doc """
  Converts an Elixir map with atom keys to a camelCase JSON map.

  Each mapping is a `{json_key, atom_key}` pair. Keys whose values are `nil`
  (or absent) are omitted from the result. Looks up both the atom key and the
  JSON-string key so the function works with either representation.
  """
  @spec encode_known_keys(map(), [{String.t(), atom()}]) :: map()
  def encode_known_keys(source, mappings) do
    Enum.reduce(mappings, %{}, fn {json_key, atom_key}, acc ->
      case Map.get(source, atom_key, Map.get(source, json_key)) do
        nil -> acc
        val -> Map.put(acc, json_key, val)
      end
    end)
  end

  defp encode_push_authentication(nil), do: nil

  defp encode_push_authentication(auth) when is_map(auth) do
    encoded =
      %{}
      |> put_unless_nil("scheme", Map.get(auth, :scheme))
      |> put_unless_nil("credentials", Map.get(auth, :credentials))

    if encoded == %{}, do: nil, else: encoded
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, val) when val == %{}, do: map
  defp put_unless_empty(map, _key, val) when val == [], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_unless_nil_nested(map, _key, nil), do: map

  defp put_unless_nil_nested(map, key, struct) do
    {:ok, encoded} = encode(struct)
    Map.put(map, key, encoded)
  end

  # -------------------------------------------------------------------
  # Private — Decoding helpers
  # -------------------------------------------------------------------

  # v0.3 discriminated the event union with a "kind" field rather than the
  # StreamResponse wrapper. Kept so a v0.3 peer's stream still decodes. Bare
  # frames with neither wrapper nor "kind" (mid-migration v0.3 peers) are
  # inferred from their required members.
  defp decode_event_by_kind(map) do
    case Map.get(map, "kind") do
      "status-update" -> decode(map, :status_update_event)
      "artifact-update" -> decode(map, :artifact_update_event)
      "task" -> decode(map, :task)
      "message" -> decode(map, :message)
      nil -> infer_bare_event(map)
      other -> {:error, {:unknown_kind, other}}
    end
  end

  defp infer_bare_event(%{"taskId" => _, "status" => %{} = status} = map)
       when map_size(status) > 0,
       do: decode(map, :status_update_event)

  defp infer_bare_event(%{"taskId" => _, "artifact" => %{} = artifact} = map)
       when map_size(artifact) > 0,
       do: decode(map, :artifact_update_event)

  defp infer_bare_event(%{"messageId" => _, "parts" => [_ | _]} = map),
    do: decode(map, :message)

  defp infer_bare_event(%{"id" => _, "status" => %{} = status} = map)
       when map_size(status) > 0,
       do: decode(map, :task)

  defp infer_bare_event(_), do: {:error, {:missing_field, "kind"}}

  defp require_field(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, field}}
    end
  end

  # The spec names this field `schemes` (an array); the TCK and the v1.0 proto
  # send a singular `scheme`. Both normalize to a single scheme internally.
  defp decode_push_authentication(map) when is_map(map) do
    scheme =
      case Map.get(map, "scheme") do
        nil -> map |> Map.get("schemes", []) |> List.first()
        scheme -> scheme
      end

    auth =
      %{}
      |> put_unless_nil(:scheme, scheme)
      |> put_unless_nil(:credentials, Map.get(map, "credentials"))

    if auth == %{}, do: nil, else: auth
  end

  defp decode_push_authentication(_), do: nil

  defp require_non_empty([], field), do: {:error, {:empty_field, field}}
  defp require_non_empty([_ | _], _field), do: :ok

  defp decode_role(str) when is_map_key(@string_to_role, str) do
    {:ok, @string_to_role[str]}
  end

  defp decode_role(str), do: {:error, {:invalid_role, str}}

  defp decode_timestamp(nil), do: {:ok, nil}

  defp decode_timestamp(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid_timestamp, str}}
    end
  end

  defp decode_base64(nil), do: {:ok, nil}

  defp decode_base64(str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_optional(nil, _type), do: {:ok, nil}
  defp decode_optional(map, type), do: decode(map, type)

  defp decode_list(items, type) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case decode(item, type) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # Parts without "kind": v1.0 is flat ({"text"|"data"|"raw"|"url": ...}),
  # v0.3 nests file content under {"file": {...}}.
  defp infer_part_type(map) do
    cond do
      Map.has_key?(map, "text") -> decode_text_part(map)
      Map.has_key?(map, "data") -> decode_data_part(map)
      Map.has_key?(map, "file") -> decode_file_part(map)
      Map.has_key?(map, "raw") or Map.has_key?(map, "url") -> decode_flat_file_part(map)
      true -> {:error, {:missing_field, "kind"}}
    end
  end

  defp decode_text_part(map) do
    with {:ok, text} <- require_field(map, "text") do
      {:ok,
       %AshA2A.Protocol.Part.Text{
         text: text,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  defp decode_file_part(map) do
    with {:ok, file_map} <- require_field(map, "file"),
         {:ok, file} <- decode(file_map, :file_content) do
      {:ok,
       %AshA2A.Protocol.Part.File{
         file: file,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  defp decode_data_part(map) do
    with {:ok, data} <- require_field(map, "data") do
      {:ok,
       %AshA2A.Protocol.Part.Data{
         data: data,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  defp decode_flat_file_part(map) do
    with {:ok, bytes} <- decode_base64(Map.get(map, "raw")) do
      file = %AshA2A.Protocol.FileContent{
        name: Map.get(map, "filename"),
        mime_type: Map.get(map, "mediaType"),
        bytes: bytes,
        uri: Map.get(map, "url")
      }

      {:ok,
       %AshA2A.Protocol.Part.File{
         file: file,
         metadata: Map.get(map, "metadata", %{})
       }}
    end
  end

  # -------------------------------------------------------------------
  # Private — AgentCard decoding helpers
  # -------------------------------------------------------------------

  defp decode_card_skills(skills) when is_list(skills) do
    Enum.reduce_while(skills, {:ok, []}, fn skill, {:ok, acc} ->
      with {:ok, id} <- require_field(skill, "id"),
           {:ok, name} <- require_field(skill, "name"),
           {:ok, description} <- require_field(skill, "description") do
        decoded =
          %{
            id: id,
            name: name,
            description: description,
            tags: Map.get(skill, "tags", [])
          }
          |> put_skill_mode_if_present(:input_modes, skill, "inputModes")
          |> put_skill_mode_if_present(:output_modes, skill, "outputModes")
          |> put_skill_security_if_present(skill)

        {:cont, {:ok, [decoded | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp decode_card_skills(_), do: {:error, {:invalid_field, "skills"}}

  # Spec AgentSkill fields 6/7: per-skill mode overrides are OPTIONAL.
  # The decoded skill map carries `:input_modes`/`:output_modes` ONLY when
  # the wire member is actually present -- absence on the wire is the
  # "inherit the card defaults" signal, so no nil-placeholder keys are
  # synthesized for cards that do not use the override.
  defp put_skill_mode_if_present(map, atom_key, wire_skill, wire_key) do
    if Map.has_key?(wire_skill, wire_key) do
      Map.put(map, atom_key, Map.get(wire_skill, wire_key))
    else
      map
    end
  end

  # Spec AgentSkill field 8: per-skill security requirements are OPTIONAL.
  # The decoded skill map carries `:security_requirements` ONLY when the wire
  # member is present -- absence on the wire is the "inherit the card-level
  # security" signal, so no nil-placeholder key is synthesized. The value
  # normalizes through the same decoder as the card-level member: both the
  # protojson wrapper shape (%{"schemes" => %{name => %{"list" => scopes}}})
  # and flat %{name => scopes} entries are accepted.
  defp put_skill_security_if_present(map, wire_skill) do
    case Map.get(wire_skill, "securityRequirements") do
      nil -> map
      reqs -> Map.put(map, :security_requirements, decode_card_security(reqs))
    end
  end

  defp decode_card_capabilities(nil), do: %{}

  defp decode_card_capabilities(map) when is_map(map) do
    base =
      decode_known_keys(map, [
        {"streaming", :streaming},
        {"pushNotifications", :push_notifications},
        {"stateTransitionHistory", :state_transition_history},
        {"extendedAgentCard", :extended_agent_card}
      ])

    case Map.get(map, "extensions") do
      list when is_list(list) and list != [] ->
        Map.put(base, :extensions, Enum.map(list, &decode_agent_extension/1))

      _ ->
        base
    end
  end

  defp decode_agent_extension(map) when is_map(map) do
    %AshA2A.Protocol.AgentExtension{
      uri: Map.fetch!(map, "uri"),
      description: Map.get(map, "description"),
      required: Map.get(map, "required", false),
      params: Map.get(map, "params")
    }
  end

  defp decode_card_interfaces(interfaces) when is_list(interfaces) do
    mappings = [
      {"url", :url},
      {"protocolBinding", :protocol_binding},
      {"protocolVersion", :protocol_version}
    ]

    Enum.map(interfaces, &decode_known_keys(&1, mappings))
  end

  defp decode_card_interfaces(_), do: []

  defp decode_card_provider(nil), do: nil

  defp decode_card_provider(map) when is_map(map) do
    decode_known_keys(map, [
      {"organization", :organization},
      {"url", :url}
    ])
  end

  defp decode_card_security_schemes(schemes) when map_size(schemes) == 0, do: %{}

  defp decode_card_security_schemes(schemes) when is_map(schemes) do
    Map.new(schemes, fn {name, scheme_map} ->
      {name, decode_security_scheme(scheme_map)}
    end)
  end

  # Normalizes EITHER wire spelling/shape of the card's security requirements to
  # the struct's flat %{name => scopes} entries:
  #
  #   - v1.0 "securityRequirements" (preferred), in the protojson wrapper shape
  #     (%{"schemes" => %{name => %{"list" => scopes}}}) or flat maps;
  #   - deprecated v0.3 "security" (flat maps), kept for legacy peers.
  defp decode_card_security([_ | _] = reqs) do
    Enum.map(reqs, fn
      %{"schemes" => schemes} when is_map(schemes) ->
        Map.new(schemes, fn
          {name, %{"list" => scopes}} when is_list(scopes) -> {name, scopes}
          {name, scopes} when is_list(scopes) -> {name, scopes}
        end)

      flat when is_map(flat) ->
        flat
    end)
  end

  defp decode_card_security(other), do: List.wrap(other)

  defp decode_security_scheme(%{"apiKeySecurityScheme" => inner}) do
    %AshA2A.Protocol.SecurityScheme.APIKey{
      name: Map.fetch!(inner, "name"),
      # v1.0 proto field is `location`; v0.3 spelled it `in` — accept both.
      in: Map.get(inner, "location") || Map.fetch!(inner, "in")
    }
  end

  defp decode_security_scheme(%{"httpAuthSecurityScheme" => inner}) do
    %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: Map.fetch!(inner, "scheme")}
  end

  defp decode_security_scheme(%{"oauth2SecurityScheme" => inner}) do
    %AshA2A.Protocol.SecurityScheme.OAuth2{
      flows: Map.fetch!(inner, "flows"),
      oauth2_metadata_url: Map.get(inner, "oauth2MetadataUrl")
    }
  end

  defp decode_security_scheme(%{"openIdConnectSecurityScheme" => inner}) do
    %AshA2A.Protocol.SecurityScheme.OpenIDConnect{
      open_id_connect_url: Map.fetch!(inner, "openIdConnectUrl")
    }
  end

  defp decode_security_scheme(%{"mtlsSecurityScheme" => _}) do
    %AshA2A.Protocol.SecurityScheme.MutualTLS{}
  end

  defp decode_known_keys(source, mappings) do
    Enum.reduce(mappings, %{}, fn {json_key, atom_key}, acc ->
      case Map.get(source, json_key) do
        nil -> acc
        val -> Map.put(acc, atom_key, val)
      end
    end)
  end

  # -------------------------------------------------------------------
  # ListTasks page envelope (the `tasks/list` result)
  # -------------------------------------------------------------------

  @doc """
  Decodes a v1.0 `ListTasksSuccess` page envelope — the wire result of a
  `tasks/list` operation — into the runtime's atom-keyed page map.

  Each entry of `"tasks"` goes through the ordinary task decode path
  (`decode/2` with `:task`). `totalSize`/`pageSize` must be integers or
  absent/`nil`; `nextPageToken` must be a string or absent/`nil`. A missing
  or non-list `"tasks"` member, a wrongly-typed scalar, or an entry the task
  decoder refuses is a typed refusal under the codec's
  `{:error, {:missing_field, _}}` convention (an entry error propagates the
  task decoder's own reason).

      iex> {:ok, page} = AshA2A.Protocol.JSON.decode_list_result(%{
      ...>   "tasks" => [
      ...>     %{"id" => "t1", "contextId" => "c1", "status" => %{"state" => "TASK_STATE_WORKING"}}
      ...>   ],
      ...>   "totalSize" => 1,
      ...>   "pageSize" => 1,
      ...>   "nextPageToken" => ""
      ...> })
      iex> page.total_size
      1
      iex> hd(page.tasks).id
      "t1"
  """
  @spec decode_list_result(term()) ::
          {:ok,
           %{
             tasks: [AshA2A.Protocol.Task.t()],
             total_size: integer() | nil,
             page_size: integer() | nil,
             next_page_token: String.t() | nil
           }}
          | {:error, term()}
  def decode_list_result(%{"tasks" => tasks} = envelope) when is_list(tasks) do
    with {:ok, decoded_tasks} <- decode_list(tasks, :task),
         {:ok, total_size} <- decode_optional_int(envelope, "totalSize"),
         {:ok, page_size} <- decode_optional_int(envelope, "pageSize"),
         {:ok, next_page_token} <- decode_optional_string(envelope, "nextPageToken") do
      {:ok,
       %{
         tasks: decoded_tasks,
         total_size: total_size,
         page_size: page_size,
         next_page_token: next_page_token
       }}
    end
  end

  def decode_list_result(%{"tasks" => _}), do: {:error, {:missing_field, "tasks"}}
  def decode_list_result(_envelope), do: {:error, {:missing_field, "tasks"}}

  defp decode_optional_int(envelope, key) do
    case Map.get(envelope, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp decode_optional_string(envelope, key) do
    case Map.get(envelope, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end
end
