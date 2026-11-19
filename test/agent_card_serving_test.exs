# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AgentCardServingTest do
  @moduledoc """
  W9 items 4, 5, 6 and 7: Agent Card serving hardening.

    * conditional GET (`If-None-Match` weak/list/`*`, `If-Modified-Since`) ->
      `304` carrying the same cache headers, on all three card routes, with a
      stable (init-time) `Last-Modified`, proven end to end by a real
      `AshA2A.Protocol.CardCache` revalidating against a real Bandit listener;
    * serve-time card signing (`:sign_with`), stable bytes and `ETag`;
    * `tasks/list` `totalSize` is the pre-pagination count under
      `:authorize_task`;
    * `capabilities.extendedAgentCard` / `pushNotifications` follow the
      configured provider / push state without dropping the card's other
      capabilities.

  Real conns, real agent GenServer, real HTTP listener. No mocks, no sleeps.
  """

  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.Plug, as: A2ATransportPlug
  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.Plug.CardServe
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.PlugFixture.GreeterAgent

  @card_path "/.well-known/agent-card.json"
  @fixed_lm ~U[2026-01-02 03:04:05Z]
  @fixed_lm_http "Fri, 02 Jan 2026 03:04:05 GMT"
  @key "w9-shared-secret-0123456789abcdef"

  setup do
    agent = :"w9_card_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)
    %{agent: agent}
  end

  defp base(agent, extra \\ []),
    do: [agent: agent, base_url: "http://localhost:4000/a2a", last_modified: @fixed_lm] ++ extra

  defp get_card(mod, opts, headers \\ []) do
    :get
    |> Plug.Test.conn(@card_path)
    |> Plug.Conn.merge_req_headers(headers)
    |> mod.call(opts)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  # {label, module, opts, expected cache-control}
  defp card_plugs(agent, extra \\ []) do
    [
      {"Protocol.Plug", AshA2A.Protocol.Plug, AshA2A.Protocol.Plug.init(base(agent, extra)),
       "public, max-age=300"},
      {"A2ATransport.Plug", A2ATransportPlug, A2ATransportPlug.init(base(agent, extra)),
       "public, max-age=300"},
      {"Transport.Plug", AshA2A.Transport.Plug, AshA2A.Transport.Plug.init(base(agent, extra)),
       "max-age=60"}
    ]
  end

  describe "conditional GET" do
    test "200 carries ETag, a stable Last-Modified and Cache-Control", %{agent: agent} do
      for {label, mod, opts, cache_control} <- card_plugs(agent) do
        first = get_card(mod, opts)
        second = get_card(mod, opts)

        assert first.status == 200, label
        assert [etag] = Plug.Conn.get_resp_header(first, "etag")
        assert etag =~ ~r/^"[0-9a-f]+"$/
        assert header(first, "last-modified") == @fixed_lm_http, label
        assert header(first, "cache-control") == cache_control, label

        # Last-Modified is init-time, not request-time: identical across requests.
        assert header(second, "last-modified") == header(first, "last-modified")
        assert header(second, "etag") == etag
      end
    end

    test "matching If-None-Match (exact, weak, in a list, *) answers 304 with the same headers",
         %{agent: agent} do
      for {label, mod, opts, cache_control} <- card_plugs(agent) do
        ok = get_card(mod, opts)
        etag = header(ok, "etag")

        for validator <- [etag, "W/" <> etag, ~s("nope", ) <> etag, ~s(W/"nope",W/) <> etag, "*"] do
          conn = get_card(mod, opts, [{"if-none-match", validator}])

          assert conn.status == 304, "#{label} #{validator}"
          assert conn.resp_body == ""
          assert header(conn, "etag") == etag
          assert header(conn, "last-modified") == @fixed_lm_http
          assert header(conn, "cache-control") == cache_control
        end
      end
    end

    test "non-matching If-None-Match answers 200 with the full card", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        conn = get_card(mod, opts, [{"if-none-match", ~s("not-the-etag")}])
        assert conn.status == 200, label
        assert %{"name" => _} = Jason.decode!(conn.resp_body)
      end
    end

    test "If-Modified-Since: not-newer -> 304, older -> 200, garbage -> 200", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        same = get_card(mod, opts, [{"if-modified-since", @fixed_lm_http}])
        assert same.status == 304, label
        assert same.resp_body == ""
        assert header(same, "last-modified") == @fixed_lm_http

        later = get_card(mod, opts, [{"if-modified-since", "Sat, 03 Jan 2026 00:00:00 GMT"}])
        assert later.status == 304, label

        older = get_card(mod, opts, [{"if-modified-since", "Thu, 01 Jan 2026 00:00:00 GMT"}])
        assert older.status == 200, label

        garbage = get_card(mod, opts, [{"if-modified-since", "yesterday-ish"}])
        assert garbage.status == 200, label
      end
    end

    test "If-None-Match takes precedence over If-Modified-Since", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        etag = header(get_card(mod, opts), "etag")

        # INM present and not matching: 200 even though IMS alone would 304.
        mismatch =
          get_card(mod, opts, [
            {"if-none-match", ~s("other")},
            {"if-modified-since", @fixed_lm_http}
          ])

        assert mismatch.status == 200, label

        # INM matching: 304 even though IMS alone would 200.
        match =
          get_card(mod, opts, [
            {"if-none-match", etag},
            {"if-modified-since", "Thu, 01 Jan 2026 00:00:00 GMT"}
          ])

        assert match.status == 304, label
      end
    end

    test "the HTTP-date helpers round-trip and reject malformed dates" do
      assert CardServe.http_date(@fixed_lm) == @fixed_lm_http
      assert {:ok, unix} = CardServe.parse_http_date(@fixed_lm_http)
      assert unix == DateTime.to_unix(@fixed_lm)
      assert CardServe.parse_http_date("Fri, 31 Feb 2026 03:04:05 GMT") == :error
      assert CardServe.parse_http_date("Fri, 02 Foo 2026 03:04:05 GMT") == :error
      assert CardServe.parse_http_date("nonsense") == :error
    end

    test "a real CardCache revalidates a stale entry against a real server and gets 304", %{
      agent: agent
    } do
      server =
        EphemeralHttp.start!(
          {AshA2A.Protocol.Plug, [agent: agent, base_url: "http://127.0.0.1:1/a2a"]}
        )

      cache_dir =
        Path.join(System.tmp_dir!(), "w9-card-cache-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(cache_dir) end)

      assert {:ok, card, :fresh} =
               AshA2A.Protocol.CardCache.fetch(server.base_url, cache_dir: cache_dir)

      assert is_binary(card.name)

      # max_age: 0 makes the stored entry stale, forcing a conditional GET with
      # the stored ETag; the plug answers 304 and the cache reports it.
      assert {:ok, revalidated, :not_modified} =
               AshA2A.Protocol.CardCache.fetch(server.base_url, cache_dir: cache_dir, max_age: 0)

      assert revalidated.name == card.name
    end
  end

  describe "card signing (:sign_with)" do
    test "serves a signed card with stable bytes and a stable ETag", %{agent: agent} do
      sign_with = [key: @key, alg: :HS256, kid: "w9-k1"]

      for {label, mod, opts, _} <- card_plugs(agent, sign_with: sign_with) do
        first = get_card(mod, opts)
        second = get_card(mod, opts)

        assert first.status == 200, label
        card = Jason.decode!(first.resp_body)
        assert [%{"protected" => _, "signature" => _}] = card["signatures"]

        # The signature verifies against the served bytes' wire card.
        assert CardSigning.verify(card, @key) == :ok
        assert {:error, _} = CardSigning.verify(card, "a-different-secret-0123456789abcdef")

        assert second.resp_body == first.resp_body, label
        assert header(second, "etag") == header(first, "etag"), label

        # ... and conditional GET works on the signed representation.
        revalidated = get_card(mod, opts, [{"if-none-match", header(first, "etag")}])
        assert revalidated.status == 304, label
      end
    end

    test "unsigned plugs serve no signatures member", %{agent: agent} do
      for {label, mod, opts, _} <- card_plugs(agent) do
        card = mod |> get_card(opts) |> Map.fetch!(:resp_body) |> Jason.decode!()
        refute match?([_ | _], card["signatures"]), label
      end
    end
  end

  describe "tasks/list totalSize under :authorize_task" do
    defp list(opts, params) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tasks/list",
          "params" => params
        })

      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> Map.fetch!("result")
    end

    defp send_task(opts) do
      {:ok, message} =
        AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "message/send",
          "params" => %{"message" => message}
        })

      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> AshA2A.Protocol.Plug.call(opts)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> get_in(["result", "task", "id"])
    end

    test "totalSize is the pre-pagination count, not the page length", %{agent: agent} do
      allow_all =
        AshA2A.Protocol.Plug.init(base(agent, authorize_task: fn _op, _task, _ctx -> :ok end))

      ids = for _ <- 1..3, do: send_task(allow_all)
      assert length(Enum.uniq(ids)) == 3

      page = list(allow_all, %{"pageSize" => 2})
      assert length(page["tasks"]) == 2
      assert page["pageSize"] == 2
      assert page["totalSize"] == 3
      assert page["nextPageToken"] != ""
    end

    test "denied tasks on the page are subtracted from the total, never below the page", %{
      agent: agent
    } do
      allow_all =
        AshA2A.Protocol.Plug.init(base(agent, authorize_task: fn _op, _task, _ctx -> :ok end))

      for _ <- 1..3, do: send_task(allow_all)

      [first | _] = list(allow_all, %{"pageSize" => 2})["tasks"]
      denied_id = first["id"]

      deny_one =
        AshA2A.Protocol.Plug.init(
          base(agent,
            authorize_task: fn _op, task, _ctx ->
              if task.id == denied_id, do: false, else: :ok
            end
          )
        )

      page = list(deny_one, %{"pageSize" => 2})
      assert length(page["tasks"]) == 1
      refute Enum.any?(page["tasks"], &(&1["id"] == denied_id))
      assert page["totalSize"] == 2
      assert page["pageSize"] == 2
    end
  end

  describe "capability consistency" do
    def extended(_identity, card), do: {:ok, card}

    defp capabilities(mod, opts),
      do:
        mod
        |> get_card(opts)
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()
        |> Map.fetch!("capabilities")

    test "extendedAgentCard follows the :extended_card provider both ways", %{agent: agent} do
      with_provider = A2ATransportPlug.init(base(agent, extended_card: &__MODULE__.extended/2))
      without = A2ATransportPlug.init(base(agent))

      # Even a card whose own capabilities claim an extended card must not
      # advertise one the plug would answer -32007 for.
      lying =
        A2ATransportPlug.init(
          base(agent,
            agent_card_opts: [capabilities: %{streaming: true, extended_agent_card: true}]
          )
        )

      assert capabilities(A2ATransportPlug, with_provider)["extendedAgentCard"] == true
      assert capabilities(A2ATransportPlug, without)["extendedAgentCard"] == false
      assert capabilities(A2ATransportPlug, lying)["extendedAgentCard"] == false
    end

    test "the card's other capabilities survive the transport overlay", %{agent: agent} do
      plain = AshA2A.Protocol.Plug.init(base(agent))
      overlaid = A2ATransportPlug.init(base(agent, extended_card: &__MODULE__.extended/2))

      plain_caps = capabilities(AshA2A.Protocol.Plug, plain)
      caps = capabilities(A2ATransportPlug, overlaid)

      assert caps["streaming"] == plain_caps["streaming"]
      assert caps["extendedAgentCard"] == true
    end

    test "pushNotifications is advertised only when push is actually served", %{agent: agent} do
      transport = :"w9_card_transport_#{System.unique_integer([:positive])}"
      start_supervised!({AshA2A.A2ATransport, name: transport})

      on = A2ATransportPlug.init(base(agent, push_notifications: true, transport: transport))
      off = A2ATransportPlug.init(base(agent, push_notifications: false, transport: transport))

      assert capabilities(A2ATransportPlug, on)["pushNotifications"] == true
      refute capabilities(A2ATransportPlug, off)["pushNotifications"] == true
    end
  end
end
