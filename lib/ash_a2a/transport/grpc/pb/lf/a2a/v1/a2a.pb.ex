defmodule Lf.A2a.V1.TaskState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "lf.a2a.v1.TaskState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :TASK_STATE_UNSPECIFIED, 0
  field :TASK_STATE_SUBMITTED, 1
  field :TASK_STATE_WORKING, 2
  field :TASK_STATE_COMPLETED, 3
  field :TASK_STATE_FAILED, 4
  field :TASK_STATE_CANCELED, 5
  field :TASK_STATE_INPUT_REQUIRED, 6
  field :TASK_STATE_REJECTED, 7
  field :TASK_STATE_AUTH_REQUIRED, 8
end

defmodule Lf.A2a.V1.Role do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "lf.a2a.v1.Role",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ROLE_UNSPECIFIED, 0
  field :ROLE_USER, 1
  field :ROLE_AGENT, 2
end

defmodule Lf.A2a.V1.SendMessageConfiguration do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SendMessageConfiguration",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :accepted_output_modes, 1, repeated: true, type: :string, json_name: "acceptedOutputModes"

  field :task_push_notification_config, 2,
    type: Lf.A2a.V1.TaskPushNotificationConfig,
    json_name: "taskPushNotificationConfig"

  field :history_length, 3, proto3_optional: true, type: :int32, json_name: "historyLength"
  field :return_immediately, 4, type: :bool, json_name: "returnImmediately"
end

defmodule Lf.A2a.V1.Task do
  @moduledoc false

  use Protobuf, full_name: "lf.a2a.v1.Task", protoc_gen_elixir_version: "0.17.0", syntax: :proto3

  field :id, 1, type: :string, deprecated: false
  field :context_id, 2, type: :string, json_name: "contextId"
  field :status, 3, type: Lf.A2a.V1.TaskStatus, deprecated: false
  field :artifacts, 4, repeated: true, type: Lf.A2a.V1.Artifact
  field :history, 5, repeated: true, type: Lf.A2a.V1.Message
  field :metadata, 6, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.TaskStatus do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.TaskStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :state, 1, type: Lf.A2a.V1.TaskState, enum: true, deprecated: false
  field :message, 2, type: Lf.A2a.V1.Message
  field :timestamp, 3, type: Google.Protobuf.Timestamp
end

defmodule Lf.A2a.V1.Part do
  @moduledoc false

  use Protobuf, full_name: "lf.a2a.v1.Part", protoc_gen_elixir_version: "0.17.0", syntax: :proto3

  oneof :content, 0

  field :text, 1, type: :string, oneof: 0
  field :raw, 2, type: :bytes, oneof: 0
  field :url, 3, type: :string, oneof: 0
  field :data, 4, type: Google.Protobuf.Value, oneof: 0
  field :metadata, 5, type: Google.Protobuf.Struct
  field :filename, 6, type: :string
  field :media_type, 7, type: :string, json_name: "mediaType"
end

defmodule Lf.A2a.V1.Message do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.Message",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :message_id, 1, type: :string, json_name: "messageId", deprecated: false
  field :context_id, 2, type: :string, json_name: "contextId"
  field :task_id, 3, type: :string, json_name: "taskId"
  field :role, 4, type: Lf.A2a.V1.Role, enum: true, deprecated: false
  field :parts, 5, repeated: true, type: Lf.A2a.V1.Part, deprecated: false
  field :metadata, 6, type: Google.Protobuf.Struct
  field :extensions, 7, repeated: true, type: :string
  field :reference_task_ids, 8, repeated: true, type: :string, json_name: "referenceTaskIds"
end

defmodule Lf.A2a.V1.Artifact do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.Artifact",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :artifact_id, 1, type: :string, json_name: "artifactId", deprecated: false
  field :name, 2, type: :string
  field :description, 3, type: :string
  field :parts, 4, repeated: true, type: Lf.A2a.V1.Part, deprecated: false
  field :metadata, 5, type: Google.Protobuf.Struct
  field :extensions, 6, repeated: true, type: :string
end

defmodule Lf.A2a.V1.TaskStatusUpdateEvent do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.TaskStatusUpdateEvent",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :task_id, 1, type: :string, json_name: "taskId", deprecated: false
  field :context_id, 2, type: :string, json_name: "contextId", deprecated: false
  field :status, 3, type: Lf.A2a.V1.TaskStatus, deprecated: false
  field :metadata, 4, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.TaskArtifactUpdateEvent do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.TaskArtifactUpdateEvent",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :task_id, 1, type: :string, json_name: "taskId", deprecated: false
  field :context_id, 2, type: :string, json_name: "contextId", deprecated: false
  field :artifact, 3, type: Lf.A2a.V1.Artifact, deprecated: false
  field :append, 4, type: :bool
  field :last_chunk, 5, type: :bool, json_name: "lastChunk"
  field :metadata, 6, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.AuthenticationInfo do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AuthenticationInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :scheme, 1, type: :string, deprecated: false
  field :credentials, 2, type: :string
end

defmodule Lf.A2a.V1.AgentInterface do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentInterface",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :url, 1, type: :string, deprecated: false
  field :protocol_binding, 2, type: :string, json_name: "protocolBinding", deprecated: false
  field :tenant, 3, type: :string
  field :protocol_version, 4, type: :string, json_name: "protocolVersion", deprecated: false
end

defmodule Lf.A2a.V1.AgentCard.SecuritySchemesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentCard.SecuritySchemesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Lf.A2a.V1.SecurityScheme
end

defmodule Lf.A2a.V1.AgentCard do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentCard",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string, deprecated: false
  field :description, 2, type: :string, deprecated: false

  field :supported_interfaces, 3,
    repeated: true,
    type: Lf.A2a.V1.AgentInterface,
    json_name: "supportedInterfaces",
    deprecated: false

  field :provider, 4, type: Lf.A2a.V1.AgentProvider
  field :version, 5, type: :string, deprecated: false
  field :documentation_url, 6, proto3_optional: true, type: :string, json_name: "documentationUrl"
  field :capabilities, 7, type: Lf.A2a.V1.AgentCapabilities, deprecated: false

  field :security_schemes, 8,
    repeated: true,
    type: Lf.A2a.V1.AgentCard.SecuritySchemesEntry,
    json_name: "securitySchemes",
    map: true

  field :security_requirements, 9,
    repeated: true,
    type: Lf.A2a.V1.SecurityRequirement,
    json_name: "securityRequirements"

  field :default_input_modes, 10,
    repeated: true,
    type: :string,
    json_name: "defaultInputModes",
    deprecated: false

  field :default_output_modes, 11,
    repeated: true,
    type: :string,
    json_name: "defaultOutputModes",
    deprecated: false

  field :skills, 12, repeated: true, type: Lf.A2a.V1.AgentSkill, deprecated: false
  field :signatures, 13, repeated: true, type: Lf.A2a.V1.AgentCardSignature
  field :icon_url, 14, proto3_optional: true, type: :string, json_name: "iconUrl"
end

defmodule Lf.A2a.V1.AgentProvider do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentProvider",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :url, 1, type: :string, deprecated: false
  field :organization, 2, type: :string, deprecated: false
end

defmodule Lf.A2a.V1.AgentCapabilities do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentCapabilities",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :streaming, 1, proto3_optional: true, type: :bool
  field :push_notifications, 2, proto3_optional: true, type: :bool, json_name: "pushNotifications"
  field :extensions, 3, repeated: true, type: Lf.A2a.V1.AgentExtension

  field :extended_agent_card, 4,
    proto3_optional: true,
    type: :bool,
    json_name: "extendedAgentCard"
end

defmodule Lf.A2a.V1.AgentExtension do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentExtension",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :uri, 1, type: :string
  field :description, 2, type: :string
  field :required, 3, type: :bool
  field :params, 4, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.AgentSkill do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentSkill",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string, deprecated: false
  field :name, 2, type: :string, deprecated: false
  field :description, 3, type: :string, deprecated: false
  field :tags, 4, repeated: true, type: :string, deprecated: false
  field :examples, 5, repeated: true, type: :string
  field :input_modes, 6, repeated: true, type: :string, json_name: "inputModes"
  field :output_modes, 7, repeated: true, type: :string, json_name: "outputModes"

  field :security_requirements, 8,
    repeated: true,
    type: Lf.A2a.V1.SecurityRequirement,
    json_name: "securityRequirements"
end

defmodule Lf.A2a.V1.AgentCardSignature do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AgentCardSignature",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :protected, 1, type: :string, deprecated: false
  field :signature, 2, type: :string, deprecated: false
  field :header, 3, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.TaskPushNotificationConfig do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.TaskPushNotificationConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :id, 2, type: :string
  field :task_id, 3, type: :string, json_name: "taskId"
  field :url, 4, type: :string, deprecated: false
  field :token, 5, type: :string
  field :authentication, 6, type: Lf.A2a.V1.AuthenticationInfo
end

defmodule Lf.A2a.V1.StringList do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.StringList",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :list, 1, repeated: true, type: :string
end

defmodule Lf.A2a.V1.SecurityRequirement.SchemesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SecurityRequirement.SchemesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: Lf.A2a.V1.StringList
end

defmodule Lf.A2a.V1.SecurityRequirement do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SecurityRequirement",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :schemes, 1, repeated: true, type: Lf.A2a.V1.SecurityRequirement.SchemesEntry, map: true
end

defmodule Lf.A2a.V1.SecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :scheme, 0

  field :api_key_security_scheme, 1,
    type: Lf.A2a.V1.APIKeySecurityScheme,
    json_name: "apiKeySecurityScheme",
    oneof: 0

  field :http_auth_security_scheme, 2,
    type: Lf.A2a.V1.HTTPAuthSecurityScheme,
    json_name: "httpAuthSecurityScheme",
    oneof: 0

  field :oauth2_security_scheme, 3,
    type: Lf.A2a.V1.OAuth2SecurityScheme,
    json_name: "oauth2SecurityScheme",
    oneof: 0

  field :open_id_connect_security_scheme, 4,
    type: Lf.A2a.V1.OpenIdConnectSecurityScheme,
    json_name: "openIdConnectSecurityScheme",
    oneof: 0

  field :mtls_security_scheme, 5,
    type: Lf.A2a.V1.MutualTlsSecurityScheme,
    json_name: "mtlsSecurityScheme",
    oneof: 0
end

defmodule Lf.A2a.V1.APIKeySecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.APIKeySecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :description, 1, type: :string
  field :location, 2, type: :string, deprecated: false
  field :name, 3, type: :string, deprecated: false
end

defmodule Lf.A2a.V1.HTTPAuthSecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.HTTPAuthSecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :description, 1, type: :string
  field :scheme, 2, type: :string, deprecated: false
  field :bearer_format, 3, type: :string, json_name: "bearerFormat"
end

defmodule Lf.A2a.V1.OAuth2SecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.OAuth2SecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :description, 1, type: :string
  field :flows, 2, type: Lf.A2a.V1.OAuthFlows, deprecated: false
  field :oauth2_metadata_url, 3, type: :string, json_name: "oauth2MetadataUrl"
end

defmodule Lf.A2a.V1.OpenIdConnectSecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.OpenIdConnectSecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :description, 1, type: :string
  field :open_id_connect_url, 2, type: :string, json_name: "openIdConnectUrl", deprecated: false
end

defmodule Lf.A2a.V1.MutualTlsSecurityScheme do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.MutualTlsSecurityScheme",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :description, 1, type: :string
end

defmodule Lf.A2a.V1.OAuthFlows do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.OAuthFlows",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :flow, 0

  field :authorization_code, 1,
    type: Lf.A2a.V1.AuthorizationCodeOAuthFlow,
    json_name: "authorizationCode",
    oneof: 0

  field :client_credentials, 2,
    type: Lf.A2a.V1.ClientCredentialsOAuthFlow,
    json_name: "clientCredentials",
    oneof: 0

  field :implicit, 3, type: Lf.A2a.V1.ImplicitOAuthFlow, oneof: 0, deprecated: true
  field :password, 4, type: Lf.A2a.V1.PasswordOAuthFlow, oneof: 0, deprecated: true
  field :device_code, 5, type: Lf.A2a.V1.DeviceCodeOAuthFlow, json_name: "deviceCode", oneof: 0
end

defmodule Lf.A2a.V1.AuthorizationCodeOAuthFlow.ScopesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AuthorizationCodeOAuthFlow.ScopesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Lf.A2a.V1.AuthorizationCodeOAuthFlow do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.AuthorizationCodeOAuthFlow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :authorization_url, 1, type: :string, json_name: "authorizationUrl", deprecated: false
  field :token_url, 2, type: :string, json_name: "tokenUrl", deprecated: false
  field :refresh_url, 3, type: :string, json_name: "refreshUrl"

  field :scopes, 4,
    repeated: true,
    type: Lf.A2a.V1.AuthorizationCodeOAuthFlow.ScopesEntry,
    map: true,
    deprecated: false

  field :pkce_required, 5, type: :bool, json_name: "pkceRequired"
end

defmodule Lf.A2a.V1.ClientCredentialsOAuthFlow.ScopesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ClientCredentialsOAuthFlow.ScopesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Lf.A2a.V1.ClientCredentialsOAuthFlow do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ClientCredentialsOAuthFlow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :token_url, 1, type: :string, json_name: "tokenUrl", deprecated: false
  field :refresh_url, 2, type: :string, json_name: "refreshUrl"

  field :scopes, 3,
    repeated: true,
    type: Lf.A2a.V1.ClientCredentialsOAuthFlow.ScopesEntry,
    map: true,
    deprecated: false
end

defmodule Lf.A2a.V1.ImplicitOAuthFlow.ScopesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ImplicitOAuthFlow.ScopesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Lf.A2a.V1.ImplicitOAuthFlow do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ImplicitOAuthFlow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :authorization_url, 1, type: :string, json_name: "authorizationUrl"
  field :refresh_url, 2, type: :string, json_name: "refreshUrl"
  field :scopes, 3, repeated: true, type: Lf.A2a.V1.ImplicitOAuthFlow.ScopesEntry, map: true
end

defmodule Lf.A2a.V1.PasswordOAuthFlow.ScopesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.PasswordOAuthFlow.ScopesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Lf.A2a.V1.PasswordOAuthFlow do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.PasswordOAuthFlow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :token_url, 1, type: :string, json_name: "tokenUrl"
  field :refresh_url, 2, type: :string, json_name: "refreshUrl"
  field :scopes, 3, repeated: true, type: Lf.A2a.V1.PasswordOAuthFlow.ScopesEntry, map: true
end

defmodule Lf.A2a.V1.DeviceCodeOAuthFlow.ScopesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.DeviceCodeOAuthFlow.ScopesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Lf.A2a.V1.DeviceCodeOAuthFlow do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.DeviceCodeOAuthFlow",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :device_authorization_url, 1,
    type: :string,
    json_name: "deviceAuthorizationUrl",
    deprecated: false

  field :token_url, 2, type: :string, json_name: "tokenUrl", deprecated: false
  field :refresh_url, 3, type: :string, json_name: "refreshUrl"

  field :scopes, 4,
    repeated: true,
    type: Lf.A2a.V1.DeviceCodeOAuthFlow.ScopesEntry,
    map: true,
    deprecated: false
end

defmodule Lf.A2a.V1.SendMessageRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SendMessageRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :message, 2, type: Lf.A2a.V1.Message, deprecated: false
  field :configuration, 3, type: Lf.A2a.V1.SendMessageConfiguration
  field :metadata, 4, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.GetTaskRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.GetTaskRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :id, 2, type: :string, deprecated: false
  field :history_length, 3, proto3_optional: true, type: :int32, json_name: "historyLength"
end

defmodule Lf.A2a.V1.ListTasksRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ListTasksRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :context_id, 2, type: :string, json_name: "contextId"
  field :status, 3, type: Lf.A2a.V1.TaskState, enum: true
  field :page_size, 4, proto3_optional: true, type: :int32, json_name: "pageSize"
  field :page_token, 5, type: :string, json_name: "pageToken"
  field :history_length, 6, proto3_optional: true, type: :int32, json_name: "historyLength"

  field :status_timestamp_after, 7,
    type: Google.Protobuf.Timestamp,
    json_name: "statusTimestampAfter"

  field :include_artifacts, 8, proto3_optional: true, type: :bool, json_name: "includeArtifacts"
end

defmodule Lf.A2a.V1.ListTasksResponse do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ListTasksResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tasks, 1, repeated: true, type: Lf.A2a.V1.Task, deprecated: false
  field :next_page_token, 2, type: :string, json_name: "nextPageToken", deprecated: false
  field :page_size, 3, type: :int32, json_name: "pageSize", deprecated: false
  field :total_size, 4, type: :int32, json_name: "totalSize", deprecated: false
end

defmodule Lf.A2a.V1.CancelTaskRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.CancelTaskRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :id, 2, type: :string, deprecated: false
  field :metadata, 3, type: Google.Protobuf.Struct
end

defmodule Lf.A2a.V1.GetTaskPushNotificationConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.GetTaskPushNotificationConfigRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :task_id, 2, type: :string, json_name: "taskId", deprecated: false
  field :id, 3, type: :string, deprecated: false
end

defmodule Lf.A2a.V1.DeleteTaskPushNotificationConfigRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.DeleteTaskPushNotificationConfigRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :task_id, 2, type: :string, json_name: "taskId", deprecated: false
  field :id, 3, type: :string, deprecated: false
end

defmodule Lf.A2a.V1.SubscribeToTaskRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SubscribeToTaskRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
  field :id, 2, type: :string, deprecated: false
end

defmodule Lf.A2a.V1.ListTaskPushNotificationConfigsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ListTaskPushNotificationConfigsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 4, type: :string
  field :task_id, 1, type: :string, json_name: "taskId", deprecated: false
  field :page_size, 2, type: :int32, json_name: "pageSize"
  field :page_token, 3, type: :string, json_name: "pageToken"
end

defmodule Lf.A2a.V1.GetExtendedAgentCardRequest do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.GetExtendedAgentCardRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tenant, 1, type: :string
end

defmodule Lf.A2a.V1.SendMessageResponse do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.SendMessageResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :payload, 0

  field :task, 1, type: Lf.A2a.V1.Task, oneof: 0
  field :message, 2, type: Lf.A2a.V1.Message, oneof: 0
end

defmodule Lf.A2a.V1.StreamResponse do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.StreamResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof :payload, 0

  field :task, 1, type: Lf.A2a.V1.Task, oneof: 0
  field :message, 2, type: Lf.A2a.V1.Message, oneof: 0

  field :status_update, 3,
    type: Lf.A2a.V1.TaskStatusUpdateEvent,
    json_name: "statusUpdate",
    oneof: 0

  field :artifact_update, 4,
    type: Lf.A2a.V1.TaskArtifactUpdateEvent,
    json_name: "artifactUpdate",
    oneof: 0
end

defmodule Lf.A2a.V1.ListTaskPushNotificationConfigsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "lf.a2a.v1.ListTaskPushNotificationConfigsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :configs, 1, repeated: true, type: Lf.A2a.V1.TaskPushNotificationConfig
  field :next_page_token, 2, type: :string, json_name: "nextPageToken"
end

defmodule Lf.A2a.V1.A2AService.Service do
  @moduledoc false

  use GRPC.Service, name: "lf.a2a.v1.A2AService", protoc_gen_elixir_version: "0.17.0"

  rpc :SendMessage, Lf.A2a.V1.SendMessageRequest, Lf.A2a.V1.SendMessageResponse

  rpc :SendStreamingMessage, Lf.A2a.V1.SendMessageRequest, stream(Lf.A2a.V1.StreamResponse)

  rpc :GetTask, Lf.A2a.V1.GetTaskRequest, Lf.A2a.V1.Task

  rpc :ListTasks, Lf.A2a.V1.ListTasksRequest, Lf.A2a.V1.ListTasksResponse

  rpc :CancelTask, Lf.A2a.V1.CancelTaskRequest, Lf.A2a.V1.Task

  rpc :SubscribeToTask, Lf.A2a.V1.SubscribeToTaskRequest, stream(Lf.A2a.V1.StreamResponse)

  rpc :CreateTaskPushNotificationConfig,
      Lf.A2a.V1.TaskPushNotificationConfig,
      Lf.A2a.V1.TaskPushNotificationConfig

  rpc :GetTaskPushNotificationConfig,
      Lf.A2a.V1.GetTaskPushNotificationConfigRequest,
      Lf.A2a.V1.TaskPushNotificationConfig

  rpc :ListTaskPushNotificationConfigs,
      Lf.A2a.V1.ListTaskPushNotificationConfigsRequest,
      Lf.A2a.V1.ListTaskPushNotificationConfigsResponse

  rpc :GetExtendedAgentCard, Lf.A2a.V1.GetExtendedAgentCardRequest, Lf.A2a.V1.AgentCard

  rpc :DeleteTaskPushNotificationConfig,
      Lf.A2a.V1.DeleteTaskPushNotificationConfigRequest,
      Google.Protobuf.Empty
end

defmodule Lf.A2a.V1.A2AService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Lf.A2a.V1.A2AService.Service
end
