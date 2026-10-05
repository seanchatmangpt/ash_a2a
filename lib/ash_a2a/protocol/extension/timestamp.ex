defmodule AshA2A.Protocol.Extension.Timestamp do
  @moduledoc """
  Reference `AshA2A.Protocol.Extension` that timestamps requests and responses.

  Stamps `Message.metadata` on the way in and `Task.metadata` on the way
  out under the extension's URI:

      "https://a2a-protocol.org/extensions/timestamp/v1" => %{
        received_at: 1_700_000_000_000,
        completed_at: 1_700_000_000_042
      }

  Times are wall-clock milliseconds via `System.system_time(:millisecond)`.

  ## Usage

  Configure on the server and (optionally) on the client. Both must declare
  the URI for the activation to round-trip.

      # Server
      Bandit.start_link(
        plug: {AshA2A.Protocol.Plug,
          agent: MyAgent,
          base_url: "http://localhost:4000",
          extensions: [AshA2A.Protocol.Extension.Timestamp]}
      )

      # Client
      client = AshA2A.Protocol.Client.new("http://localhost:4000",
        extensions: [AshA2A.Protocol.Extension.Timestamp])

      {:ok, task} = AshA2A.Protocol.Client.send_message(client, "hi")
      task.metadata["https://a2a-protocol.org/extensions/timestamp/v1"]
      #=> %{"received_at" => 1700000000000, "completed_at" => 1700000000042}

  Map keys are atoms on the server (before encoding) and strings on the
  client (after JSON decode).

  ## What this exercises

  This module implements every optional callback of `AshA2A.Protocol.Extension`:

    * `c:AshA2A.Protocol.Extension.declaration/1` — non-required profile extension.
    * `c:AshA2A.Protocol.Extension.activate/3` — captures the per-request start time.
    * `c:AshA2A.Protocol.Extension.handle_request/3` — stamps the inbound message metadata.
    * `c:AshA2A.Protocol.Extension.handle_response/3` — stamps the outbound task metadata.

  Copy it as a starting template for your own profile-style extension.
  """

  @behaviour AshA2A.Protocol.Extension

  @uri "https://a2a-protocol.org/extensions/timestamp/v1"

  @typedoc """
  Activation state: the wall-clock millisecond when the request was first
  observed by the server.
  """
  @type activation :: %{received_at: integer()}

  @doc "The stable URI advertised by this extension."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl AshA2A.Protocol.Extension
  def declaration(_state) do
    %AshA2A.Protocol.AgentExtension{
      uri: @uri,
      description: "Stamps requests and responses with wall-clock milliseconds."
    }
  end

  @impl AshA2A.Protocol.Extension
  def activate(_requested, _ctx, _state) do
    {:ok, %{received_at: System.system_time(:millisecond)}}
  end

  @impl AshA2A.Protocol.Extension
  def handle_request(message, params, %{received_at: t} = activation) do
    message = AshA2A.Protocol.Extension.put_metadata(message, __MODULE__, %{received_at: t})
    {:ok, message, params, activation}
  end

  @impl AshA2A.Protocol.Extension
  def handle_response(task, _params, %{received_at: t} = activation) do
    stamp = %{received_at: t, completed_at: System.system_time(:millisecond)}
    {:ok, AshA2A.Protocol.Extension.put_metadata(task, __MODULE__, stamp), activation}
  end
end
