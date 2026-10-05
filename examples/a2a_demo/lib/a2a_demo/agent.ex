defmodule A2aDemo.Agent do
  @moduledoc """
  The demo's `AshA2A.Agent` GenServer: a real, supervised agent over
  `A2aDemo.Note`, its card projected from the compiled capability index --
  never hand-written.

  In TCK mode (`A2A_DEMO_TCK=1` at compile time) the agent adds one SUT
  affordance: a message whose metadata names no skill defaults to the
  observe read (`get_note`). The A2A TCK drives the SUT with plain messages
  carrying no `skill` metadata; a two-skill agent without a default refuses
  them `{:ambiguous_skill, ...}`, which would cap every transport's matrix
  at the SUT shape rather than the transport. Read-only by construction:
  the default skill is the `:observe` read; `create_note` stays grant-gated
  and is only ever reachable by explicit `skill` metadata.
  """

  use AshA2A.Agent,
    resource_or_domain: A2aDemo.Note,
    name: "a2a-demo",
    description:
      "Demo agent: an ETS-backed note store with an observe read and a grant-gated create.",
    supported_interfaces: [
      %{
        url: "http://localhost:#{System.get_env("A2A_DEMO_PORT") || "4010"}/jsonrpc",
        protocol_binding: "JSONRPC"
      },
      %{
        url: "http://localhost:#{System.get_env("A2A_DEMO_PORT") || "4010"}/rest",
        protocol_binding: "HTTP+JSON"
      },
      %{
        url: "localhost:#{System.get_env("A2A_DEMO_GRPC_PORT") || "4011"}",
        protocol_binding: "GRPC"
      }
    ]

  if System.get_env("A2A_DEMO_TCK") == "1" do
    @impl AshA2A.Protocol.Agent
    def handle_message(message, context) do
      metadata = message.metadata || %{}

      message =
        if AshA2A.MetadataKey.get(metadata, :skill) do
          message
        else
          %{message | metadata: Map.put(metadata, "skill", "get_note")}
        end

      AshA2A.Agent.__dispatch__(A2aDemo.Note, message, context, [])
    end
  end
end
