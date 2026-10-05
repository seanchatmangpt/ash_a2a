defmodule AshA2A.Protocol.AgentExtension do
  @moduledoc """
  Declaration of a protocol extension supported by an agent.

  Mirrors the `AgentExtension` object from the A2A v1.0 spec. Used both as a
  struct embedded in `AgentCard.capabilities.extensions` and as the value
  returned by an `AshA2A.Protocol.Extension` module's `declaration/1` callback.

  ## Fields

    * `:uri` — unique identifier for the extension (required)
    * `:description` — human-readable description of how the agent uses it
    * `:required` — if `true`, clients must declare support via the
      `A2A-Extensions` request header; otherwise the server returns
      `ExtensionSupportRequiredError` (-32008). Defaults to `false`.
    * `:params` — optional extension-specific configuration parameters

  ## Examples

      %AshA2A.Protocol.AgentExtension{
        uri: "https://a2a-protocol.org/extensions/timestamp",
        description: "Adds timestamps to messages and artifacts"
      }

      %AshA2A.Protocol.AgentExtension{
        uri: "https://a2a-protocol.org/extensions/secure-passport",
        description: "Personalization via signed passport",
        required: true,
        params: %{"version" => "1.0"}
      }
  """

  @type t :: %__MODULE__{
          uri: String.t(),
          description: String.t() | nil,
          required: boolean(),
          params: map() | nil
        }

  @enforce_keys [:uri]
  defstruct [:uri, :description, :params, required: false]
end
