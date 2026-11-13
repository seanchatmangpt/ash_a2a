# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.T1.Resource do
  @moduledoc "Real fixture: `:converse` parks in input_required when :text is omitted."

  use Ash.Resource,
    domain: AshA2A.T1.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:text, :string, allow_nil?: false)

      run(fn input, _context -> {:ok, %{text: input.arguments.text}} end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.T1.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.T1.Resource)
  end
end

defmodule AshA2A.T1.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.T1.Resource,
    name: "t1_downgrade_agent",
    capabilities: %{streaming: true}
end

defmodule AshA2A.T1.Pipeline do
  @moduledoc false
  @behaviour Plug

  def init(opts), do: AshA2A.Transport.Plug.init(opts)

  def call(conn, opts) do
    conn
    |> AshA2A.Protocol.Plug.Auth.put_identity(%{identity: "alice"})
    |> AshA2A.Transport.Plug.call(opts)
  end
end

defmodule AshA2A.T1.DowngradeWireTest do
  @moduledoc """
  T1: an explicit `A2A-Version: 1.0` consumer (the official TCK) never sees
  v1.1-only wire fields; 1.1 and header-less consumers do.
  """

  use ExUnit.Case, async: false

  @moduletag :serial_shard

  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.Test.EphemeralHttp

  @deadline_ms 5_000
  @v10_keys ["generation", "timeline", "startGeneration", "endGeneration"]

  setup do
    {_sup, _registry} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [AshA2A.T1.Agent])

    versions = Enum.uniq(AshA2A.Protocol.Version.supported_default() ++ ["1.0", "1.1"])
    opts = [agent: AshA2A.T1.Agent, base_url: "http://127.0.0.1/t1", versions: versions]
    {:ok, server: EphemeralHttp.start!({AshA2A.T1.Pipeline, opts})}
  end

  defp parked, do: AshA2A.Protocol.JSON.encode!(Message.new_user([Part.Data.new(%{})]))

  defp envelope(method, params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }

  defp rpc(server, method, params, headers) do
    Req.post!(
      url: server.base_url <> "/",
      json: envelope(method, params),
      headers: headers,
      retry: false
    ).body
  end

  defp send_task(server, headers) do
    assert %{"result" => %{"task" => %{"id" => _} = task}} =
             rpc(server, "message/send", %{"message" => parked()}, headers)

    task
  end

  defp frames(buffer) do
    buffer
    |> String.split("\n\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn
      "data: " <> json -> [Jason.decode!(json)]
      _ -> []
    end)
  end

  # Streams message/stream until the first frame carrying `"task"` or a terminal
  # frame arrived, returning every decoded frame.
  defp stream(server, headers) do
    resp =
      Req.post!(
        url: server.base_url <> "/",
        json: envelope("message/stream", %{"message" => parked()}),
        headers: headers,
        retry: false,
        into: :self,
        receive_timeout: 20_000
      )

    assert resp.status == 200
    deadline = System.monotonic_time(:millisecond) + @deadline_ms
    out = collect(resp, "", deadline)
    Req.cancel_async_response(resp)
    out
  end

  defp collect(resp, buffer, deadline) do
    all = frames(buffer)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Enum.any?(all, &match?(%{"result" => %{"task" => _}}, &1)) and length(all) >= 1 -> all
      remaining <= 0 -> flunk("deadline; frames so far: #{inspect(all)}")
      true -> receive_more(resp, buffer, deadline, remaining)
    end
  end

  defp receive_more(resp, buffer, deadline, remaining) do
    receive do
      msg ->
        case Req.parse_message(resp, msg) do
          {:ok, chunks} ->
            collect(resp, buffer <> for({:data, d} <- chunks, into: "", do: d), deadline)

          _ ->
            collect(resp, buffer, deadline)
        end
    after
      remaining -> flunk("deadline; frames so far: #{inspect(frames(buffer))}")
    end
  end

  defp deep_keys(term, acc \\ [])
  defp deep_keys(%{} = m, acc), do: Enum.reduce(m, acc, fn {k, v}, a -> deep_keys(v, [k | a]) end)
  defp deep_keys(l, acc) when is_list(l), do: Enum.reduce(l, acc, &deep_keys/2)
  defp deep_keys(_, acc), do: acc

  test "1.0 message/send result carries none of the v1.1 keys", %{server: server} do
    task = send_task(server, [{"a2a-version", "1.0"}])
    keys = deep_keys(task)
    for k <- @v10_keys, do: refute(k in keys, "leaked #{k}: #{inspect(task)}")
  end

  test "1.1 and header-less message/send results keep generation", %{server: server} do
    assert %{"generation" => _} = send_task(server, [{"a2a-version", "1.1"}])
    assert %{"generation" => _} = send_task(server, [])
  end

  test "1.0 message/stream frames carry none of the v1.1 keys", %{server: server} do
    frames = stream(server, [{"a2a-version", "1.0"}])
    assert frames != []
    keys = deep_keys(frames)
    for k <- @v10_keys, do: refute(k in keys, "leaked #{k}: #{inspect(frames)}")
  end

  test "1.1 message/stream frames carry generation", %{server: server} do
    assert "generation" in deep_keys(stream(server, [{"a2a-version", "1.1"}]))
  end

  test "header-less message/stream frames carry generation", %{server: server} do
    assert "generation" in deep_keys(stream(server, []))
  end
end
