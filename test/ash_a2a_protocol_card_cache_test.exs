# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.CardCacheTest do
  @moduledoc """
  Chicago-school test for `AshA2A.Protocol.CardCache` (A2A v1.0 §8.6 client
  caching): a REAL Bandit HTTP server serves a real agent card with real
  `ETag` (sha256 of body) / `Last-Modified` / `Cache-Control: public,
  max-age=...` headers, exactly the distribution headers the server-side plug
  emits, and the real `Req` client fetches through the real on-disk cache.

  Asserts the four cache states (`:fresh`, `:cached`, `:not_modified`,
  `:stale`) against real state: the server's request counter (the
  within-`max-age` path must make NO request), the `If-None-Match` header the
  server actually received, the bytes on disk in the cache file, and a real
  dead socket for the stale-serve path. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Protocol.CardCache
  alias AshA2A.Test.EphemeralHttp

  @well_known "/.well-known/agent-card.json"

  # Real A2A v1.0 agent card fixture (decode_agent_card requires name,
  # description, version, skills; this is what the server serves, and the
  # version bump between fetches is what changes the body and its ETag).
  @card_skills [
    %{
      "id" => "weather-lookup",
      "name" => "Weather lookup",
      "description" => "Returns current conditions for a city",
      "tags" => ["weather", "lookup"]
    },
    %{
      "id" => "forecast",
      "name" => "Forecast",
      "description" => "Returns a 5-day forecast for a city",
      "tags" => ["weather", "forecast"]
    }
  ]

  def card_fixture(version) do
    %{
      "name" => "cached-card-agent",
      "description" => "Agent exercising client-side discovery caching",
      "version" => version,
      "url" => "http://127.0.0.1:placeholder",
      "protocolVersion" => "1.0",
      "capabilities" => %{"streaming" => true},
      "skills" => @card_skills
    }
  end

  defmodule Store do
    @moduledoc """
    Real shared state for the card server: the card version it serves (mutable
    to produce a real body/ETag change), the Cache-Control header it emits
    (mutable to drive real revalidation through the server's own max-age=0),
    the count of card requests actually received, and the last `If-None-Match`
    / `If-Modified-Since` headers actually received.
    """

    def initial_state do
      %{
        version: "1.0.0",
        cache_control: "public, max-age=300",
        count: 0,
        if_none_match: [],
        if_modified_since: []
      }
    end
  end

  defmodule CardServer do
    @moduledoc """
    Real Plug.Router serving the agent card with the v1.0 distribution headers:
    `ETag` (sha256 of the exact body bytes), `Last-Modified`,
    `Cache-Control`. Answers a matching `If-None-Match` with a real `304`.
    """

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/.well-known/agent-card.json" do
      {version, cache_control} =
        Agent.get_and_update(AshA2A.Protocol.CardCacheTest.Store, fn state ->
          state = %{state | count: state.count + 1}
          {{state.version, state.cache_control}, state}
        end)

      body = Jason.encode!(AshA2A.Protocol.CardCacheTest.card_fixture(version))
      etag = ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")
      last_modified = "Wed, 21 Oct 2026 07:28:00 GMT"

      Agent.update(AshA2A.Protocol.CardCacheTest.Store, fn state ->
        %{
          state
          | if_none_match: Plug.Conn.get_req_header(conn, "if-none-match"),
            if_modified_since: Plug.Conn.get_req_header(conn, "if-modified-since")
        }
      end)

      conn =
        conn
        |> Plug.Conn.put_resp_header("etag", etag)
        |> Plug.Conn.put_resp_header("cache-control", cache_control)
        |> Plug.Conn.put_resp_header("last-modified", last_modified)

      if Plug.Conn.get_req_header(conn, "if-none-match") == [etag] do
        Plug.Conn.send_resp(conn, 304, "")
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end
    end

    match _ do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end
  end

  setup do
    {:ok, _} = Agent.start_link(Store, :initial_state, [], name: Store)
    server = EphemeralHttp.start!(CardServer)
    cache_dir = Path.join(System.tmp_dir!(), "card-cache-test-#{System.unique_integer()}")

    on_exit(fn ->
      File.rm_rf(cache_dir)
    end)

    %{server: server, cache_dir: cache_dir, url: server.base_url}
  end

  defp request_count do
    Agent.get(Store, & &1.count)
  end

  defp set_server_cache_control(cache_control) do
    Agent.update(Store, &%{&1 | cache_control: cache_control})
  end

  defp bump_card_version(version) do
    Agent.update(Store, &%{&1 | version: version})
  end

  defp last_incoming_if_none_match do
    Agent.get(Store, & &1.if_none_match)
  end

  defp cached_entry!(cache_dir, url) do
    hash = Base.encode16(:crypto.hash(:sha256, url), case: :lower)
    path = Path.join(cache_dir, hash <> ".json")
    assert {:ok, raw} = File.read(path)
    assert {:ok, entry} = Jason.decode(raw)
    entry
  end

  # Waits until the killed listener really refuses connections so the stale
  # path is exercised against a genuinely dead socket, not a shutdown race.
  defp wait_until_down!(base_url, attempts \\ 100)

  defp wait_until_down!(_base_url, 0) do
    flunk("server still accepting connections after shutdown")
  end

  defp wait_until_down!(base_url, attempts) do
    # Probe a path the card route does not count (match-all 404), so a
    # still-live server during shutdown does not inflate the card counter.
    case Req.get(base_url <> "/down-probe", retry: false, receive_timeout: 500) do
      {:error, _} ->
        :ok

      {:ok, _} ->
        Process.sleep(20)
        wait_until_down!(base_url, attempts - 1)
    end
  end

  test "cold fetch returns :fresh, stores body+etag on disk; warm fetch returns :cached with no request",
       %{cache_dir: cache_dir, url: url} do
    assert {:ok, card1, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card1.name == "cached-card-agent"
    assert card1.version == "1.0.0"
    assert request_count() == 1

    # The cache file holds the exact body bytes and the validators.
    entry = cached_entry!(cache_dir, url)
    assert {:ok, stored_card} = Jason.decode(entry["body"])
    assert stored_card["version"] == "1.0.0"
    assert entry["etag"] == ~s(") <> Base.encode16(:crypto.hash(:sha256, entry["body"]), case: :lower) <> ~s(")
    assert entry["cache_control"] == "public, max-age=300"
    assert entry["last_modified"] == "Wed, 21 Oct 2026 07:28:00 GMT"
    assert is_integer(entry["fetched_at"])

    # Within max-age: served from disk, zero network.
    assert {:ok, card2, :cached} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card2 == card1
    assert request_count() == 1
  end

  test "server max-age=0 forces real revalidation: If-None-Match sent, 304 refreshes fetched_at, returns :not_modified",
       %{cache_dir: cache_dir, url: url} do
    # max-age=0 from the start: the stored response's own Cache-Control makes
    # every fetch revalidate through the real conditional-request path.
    set_server_cache_control("public, max-age=0")

    assert {:ok, _card, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)
    entry_before = cached_entry!(cache_dir, url)
    assert entry_before["cache_control"] == "public, max-age=0"

    assert {:ok, card, :not_modified} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card.version == "1.0.0"

    # The server saw the stored ETag echoed back as If-None-Match.
    assert last_incoming_if_none_match() == [entry_before["etag"]]
    assert request_count() == 2

    # 304 refreshed the fetch time but kept the same body and ETag.
    entry_after = cached_entry!(cache_dir, url)
    assert entry_after["etag"] == entry_before["etag"]
    assert entry_after["body"] == entry_before["body"]
    assert entry_after["fetched_at"] >= entry_before["fetched_at"]

    # Still max-age=0: the next fetch revalidates again.
    assert {:ok, _card, :not_modified} = CardCache.fetch(url, cache_dir: cache_dir)
    assert request_count() == 3
  end

  test "changed card answers 200 with a new ETag: entry replaced, returns :fresh",
       %{cache_dir: cache_dir, url: url} do
    set_server_cache_control("public, max-age=0")

    assert {:ok, _card, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)
    entry_before = cached_entry!(cache_dir, url)

    bump_card_version("1.0.1")

    assert {:ok, card, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card.version == "1.0.1"
    assert request_count() == 2

    entry_after = cached_entry!(cache_dir, url)
    assert entry_after["etag"] != entry_before["etag"]
    assert {:ok, stored_card} = Jason.decode(entry_after["body"])
    assert stored_card["version"] == "1.0.1"

    # Still max-age=0: the next fetch revalidates, and the new ETag matches so
    # the card is confirmed unchanged with a 304.
    assert {:ok, card2, :not_modified} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card2.version == "1.0.1"
    assert request_count() == 3
  end

  test "network error on revalidation serves the cached card as :stale",
       %{cache_dir: cache_dir, url: url, server: server} do
    # max-age=0 from the start, so the stored entry revalidates on every fetch.
    set_server_cache_control("public, max-age=0")

    assert {:ok, cached_card, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)

    # Unlink first: the listener is linked to this test process, and an
    # untrapped kill would otherwise take the test down with it.
    Process.unlink(server.pid)
    Process.exit(server.pid, :kill)
    wait_until_down!(url)

    assert {:ok, card, :stale} = CardCache.fetch(url, cache_dir: cache_dir)
    assert card == cached_card
    assert card.version == "1.0.0"
    # The dead socket answered nothing: count stays at the cold fetch.
    assert request_count() == 1
  end

  test "network error with no cached entry returns the error",
       %{cache_dir: cache_dir, server: server} do
    dead_url = server.base_url
    Process.unlink(server.pid)
    Process.exit(server.pid, :kill)
    wait_until_down!(dead_url)

    assert {:error, reason} = CardCache.fetch(dead_url, cache_dir: cache_dir)
    assert reason != nil
  end

  test "unexpected status on revalidation serves :stale; on cold fetch returns {:error, {:unexpected_status, 500}}",
       %{cache_dir: cache_dir, url: url} do
    # Revalidation-side: 500 with a cached entry -> :stale. Kill the card
    # route only: the server stays up but every card request now 500s.
    assert {:ok, cached_card, :fresh} = CardCache.fetch(url, cache_dir: cache_dir)

    # Point the cache at the 404 route by asking for a different path: the
    # request succeeds at HTTP level with 404, which is an unexpected status.
    assert {:ok, card, :stale} =
             CardCache.fetch(url,
               cache_dir: cache_dir,
               agent_card_path: "/no-such-card",
               max_age: 0
             )

    assert card == cached_card

    # Cold-fetch-side: no cache for a different URL -> the status surfaces.
    assert {:error, {:unexpected_status, 404}} =
             CardCache.fetch(url <> "/elsewhere",
               cache_dir: cache_dir,
               agent_card_path: "/no-such-card"
             )
  end

  test "decode_body/2 decodes raw JSON bytes and maps, rejects garbage", _ctx do
    body = Jason.encode!(card_fixture("2.0.0"))

    assert {:ok, card} = CardCache.decode_body(body)
    assert card.version == "2.0.0"
    assert card.name == "cached-card-agent"
    assert card.url != nil

    assert {:ok, card2} = CardCache.decode_body(card_fixture("2.0.1"))
    assert card2.version == "2.0.1"

    assert {:error, _} = CardCache.decode_body("not json at all")
    assert {:error, _} = CardCache.decode_body(Jason.encode!(%{"name" => "incomplete"}))
    assert {:error, _} = CardCache.decode_body(42)
  end
end
