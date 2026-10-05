# A2A TCK SUT harness for ash_a2a (lane AT2).
#
# Run from /Users/sac/ash_a2a with:
#   MIX_ENV=test mix run --no-start tck_sut.exs
#
# Boots a real AshA2A.Agent (handle_message/2 overridden — the same seam the
# reference Python SUT hand-implements) behind the real owned transport
# (AshA2A.Transport.Plug) on a real Bandit listener, port from
# TCK_SUT_PORT (default 9999).
#
# The messageId-prefix routing table mirrors the official reference SUT
# (a2a-tck sut/a2a-python/sut_agent handler). That prefix contract is the
# TCK's own behavioral harness, not protocol logic.

defmodule TckSut.Resource do
  use Ash.Resource,
    domain: TckSut.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:message, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule TckSut.Domain do
  use Ash.Domain
end

defmodule TckSut.Agent do
  @moduledoc false

  use AshA2A.Agent,
    resource_or_domain: TckSut.Resource,
    name: "tck_sut_agent",
    require_authenticated_caller: false

  alias AshA2A.Protocol.Part

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _ctx) do
    id = message.message_id || ""

    cond do
      String.starts_with?(id, "tck-stream-artifact-chunked") ->
        {:stream, [Part.Text.new("chunk-1 "), Part.Text.new("chunk-2")]}

      String.starts_with?(id, "test-resubscribe-message-id") ->
        {:stream,
         Stream.map([:go], fn _ ->
           Process.sleep(4_000)
           Part.Text.new("done")
         end)}

      String.starts_with?(id, "tck-stream-artifact-text") ->
        {:stream, [Part.Text.new("Streamed text content")]}

      String.starts_with?(id, "tck-stream-artifact-file") ->
        {:stream, [file_part()]}

      String.starts_with?(id, "tck-stream-ordering-001") ->
        {:stream, [Part.Text.new("Ordered output")]}

      String.starts_with?(id, "tck-stream-001") ->
        {:stream, [Part.Text.new("Stream hello from TCK")]}

      String.starts_with?(id, "tck-stream-002") ->
        {:stream, []}

      String.starts_with?(id, "tck-stream-003") ->
        {:stream, [Part.Text.new("Stream task lifecycle")]}

      String.starts_with?(id, "tck-artifact-file-url") ->
        {:reply, [url_file_part()]}

      String.starts_with?(id, "tck-message-response") ->
        {:message, [Part.Text.new("Direct message response")]}

      String.starts_with?(id, "tck-input-required") ->
        {:input_required, [Part.Text.new("Need more input")]}

      String.starts_with?(id, "tck-complete-task") ->
        {:reply, [Part.Text.new("Hello from TCK")]}

      String.starts_with?(id, "tck-artifact-text") ->
        {:reply, [Part.Text.new("Generated text content")]}

      String.starts_with?(id, "tck-artifact-file") ->
        {:reply, [file_part()]}

      String.starts_with?(id, "tck-artifact-data") ->
        {:reply, [Part.Data.new(%{"key" => "value", "count" => 42})]}

      String.starts_with?(id, "tck-passthrough") ->
        {:reply, [Part.Text.new("Echo reply")]}

      String.starts_with?(id, "tck-reject-task") ->
        {:error, :forbidden}

      true ->
        # Reference-SUT default: complete with an echo of the unhandled id.
        {:reply, [Part.Text.new("Unhandled messageId prefix: " <> id)]}
    end
  end

  defp file_part do
    Part.File.new(
      AshA2A.Protocol.FileContent.from_bytes("tck", name: "output.txt", mime_type: "text/plain")
    )
  end

  defp url_file_part do
    Part.File.new(
      AshA2A.Protocol.FileContent.from_uri("https://example.com/output.txt",
        name: "output.txt",
        mime_type: "text/plain"
      )
    )
  end
end

defmodule TckSut.Router do
  @moduledoc false
  def init(opts) do
    opts
    |> Map.new()
    |> Map.update!(:jsonrpc, fn {mod, o} -> mod.init(o) end)
    |> Map.update!(:rest, fn {mod, o} -> mod.init(o) end)
  end

  def call(%{path_info: ["a2a", "rest" | rest]} = conn, opts) do
    AshA2A.Transport.HTTPJSON.call(%{conn | path_info: rest}, opts.rest)
  end

  def call(conn, opts), do: AshA2A.Transport.Plug.call(conn, opts.jsonrpc)
end

port = System.get_env("TCK_SUT_PORT", "9999") |> String.to_integer()
base_url = "http://127.0.0.1:#{port}"

interfaces = [
  %{url: base_url, protocol_binding: "JSONRPC", protocol_version: "1.0"},
  %{url: "#{base_url}/a2a/rest", protocol_binding: "HTTP+JSON", protocol_version: "1.0"}
]

{:ok, _} = TckSut.Agent.start_link([])

{:ok, srv} =
  Bandit.start_link(
    plug:
      {TckSut.Router,
       jsonrpc:
         {AshA2A.Transport.Plug, agent: TckSut.Agent, base_url: base_url,
          agent_card_opts: [supported_interfaces: interfaces]},
       rest:
         {AshA2A.Transport.HTTPJSON, agent: TckSut.Agent, base_url: base_url}},
    port: port,
    ip: {127, 0, 0, 1}
  )

{:ok, {_, bound}} = ThousandIsland.listener_info(srv)
IO.puts("TCK SUT listening on http://127.0.0.1:#{bound}")
Process.sleep(:infinity)
