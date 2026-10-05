# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.SpecMappingDocTest.DocAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent: replies, or streams when the text is "stream".
  use AshA2A.Protocol.Agent, name: "doc-agent", description: "spec mapping fixture"

  @impl AshA2A.Protocol.Agent
  def handle_message(message, _context) do
    case AshA2A.Protocol.Message.text(message) do
      "stream" -> {:stream, [AshA2A.Protocol.Part.Text.new("s1")]}
      _ -> {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
    end
  end
end

defmodule AshA2A.A2ATransport.SpecMappingDocTest do
  @moduledoc """
  Drift court for `docs/reference/a2a-spec-version-mapping.md`: every method
  row is driven through the real vendored `AshA2A.Protocol.Plug` and the real
  `AshA2A.A2ATransport.Plug` (real agent GenServer, real transport tree,
  real `Plug.Test` conns), and the observed outcome must equal the doc cell.
  The alias surface is read from the dependency's own source so a new
  upstream method fails here until it is documented and routed.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.SpecMappingDocTest.DocAgent

  @doc_path "docs/reference/a2a-spec-version-mapping.md"

  setup do
    uniq = System.unique_integer([:positive])
    agent = :"doc_agent_#{uniq}"
    transport = :"a2a_transport_doc_#{uniq}"
    start_supervised!({DocAgent, name: agent})
    start_supervised!({AshA2A.A2ATransport, name: transport})

    vendored = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://x/a2a")

    ours =
      TransportPlug.init(
        agent: agent,
        base_url: "http://x/a2a",
        transport: transport,
        push_notifications: true,
        extended_card: fn _identity, card -> {:ok, card} end,
        max_idle_ms: 200,
        heartbeat_ms: 100
      )

    %{vendored: {AshA2A.Protocol.Plug, vendored}, ours: {TransportPlug, ours}}
  end

  defp doc_rows do
    @doc_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\| (\w+) \| `([^`]+)` \| ([^|]+?) \| ([^|]+?) \|$/, line) do
        [_, alias_name, method, vendored, ours] -> [{alias_name, method, vendored, ours}]
        nil -> []
      end
    end)
  end

  defp dep_aliases do
    # Source of truth is now the ported in-repo JSON-RPC dispatcher
    # (lib/ash_a2a/protocol/jsonrpc.ex) — the hex `:a2a` package was removed.
    src = File.read!("lib/ash_a2a/protocol/jsonrpc.ex")
    [_, block] = Regex.run(~r/@method_aliases %\{(.*?)\n  \}/s, src)

    ~r/"(\w+)" => "([^"]+)"/
    |> Regex.scan(block)
    |> Map.new(fn [_, k, v] -> {k, v} end)
  end

  defp rpc({mod, opts}, method, params) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.Auth.put_identity(%{sub: "doc-test"})
      |> mod.call(opts)

    ct = conn |> Plug.Conn.get_resp_header("content-type") |> List.first("")

    cond do
      ct =~ "text/event-stream" -> "sse"
      true -> outcome(Jason.decode!(conn.resp_body))
    end
  end

  defp outcome(%{"error" => %{"code" => code}}), do: "error #{code}"
  defp outcome(%{"result" => _}), do: "result"

  defp msg(text) do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user(text))
    encoded
  end

  defp params_for(method, task_id) do
    push = %{"id" => "cfg", "url" => "https://93.184.215.14/hook"}

    case method do
      "message/send" ->
        %{"message" => msg("hi")}

      "message/stream" ->
        %{"message" => msg("stream")}

      "tasks/list" ->
        %{}

      "tasks/pushNotificationConfig/set" ->
        %{"taskId" => task_id, "pushNotificationConfig" => push}

      "tasks/pushNotificationConfig/" <> _ ->
        %{"id" => task_id, "pushNotificationConfigId" => "cfg"}

      _ ->
        %{"id" => task_id}
    end
  end

  defp new_task({_, _} = plug) do
    {mod, opts} = plug

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => msg("x")}
      })

    :post
    |> Plug.Test.conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> mod.call(opts)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
    |> get_in(["result", "task", "id"])
  end

  test "the doc's alias table equals AshA2A.Protocol.JSONRPC's dispatch surface and the plug's routing table" do
    rows = doc_rows()
    documented = Map.new(rows, fn {a, m, _, _} -> {a, m} end)

    assert documented == dep_aliases()
    assert TransportPlug.method_aliases() == dep_aliases()
  end

  test "every documented outcome is the observed outcome on both plugs", ctx do
    for {label, column} <- [vendored: 2, ours: 3] do
      plug = Map.fetch!(ctx, label)
      task_id = new_task(plug)

      # Seed a config first so get/list/delete observe an existing config.
      if label == :ours,
        do:
          rpc(
            plug,
            "tasks/pushNotificationConfig/set",
            params_for("tasks/pushNotificationConfig/set", task_id)
          )

      for {alias_name, method, _, _} = row <- doc_rows() do
        expected = row |> elem(column) |> String.trim()
        observed = rpc(plug, method, params_for(method, task_id))

        assert observed == expected,
               "#{label} #{method}: doc says #{expected}, observed #{observed}"

        if method != "tasks/pushNotificationConfig/delete" do
          # The PascalCase alias behaves identically to the canonical name.
          assert rpc(plug, alias_name, params_for(method, task_id)) == observed,
                 "#{label} #{alias_name}"
        end
      end
    end
  end

  test "the Version line tracks mix.exs and profile constants match the code" do
    doc = File.read!(@doc_path)
    assert doc =~ "Version: v#{Mix.Project.config()[:version]}\n"
    assert doc =~ "`#{AshA2A.Semantic.Extension.profile_id()}`"
    assert doc =~ "`#{AshA2A.Semantic.Extension.profile_uri()}`"
    assert doc =~ "`#{AshA2A.SA2A.Conformance.profile()}`"
  end
end
