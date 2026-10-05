# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PlugAgentCardTest do
  @moduledoc """
  Real, end-to-end test for assignment #3 (ash_a2a AshA2A.Protocol.Plug agent-card
  serving hardening): fronts a real, running `AshA2A.Agent`-generated
  `AshA2A.Protocol.Agent` GenServer (`AshA2A.Test.PlugFixture.GreeterAgent`) with a real
  `AshA2A.Protocol.Plug`, drives a real `Plug.Test` GET request against the well-known
  agent-card path, and asserts the real HTTP response body matches what
  `AshA2A.Info.agent_card/2` + `AshA2A.Protocol.JSON.encode_agent_card/2` produce
  directly from the same compiled capability index.

  Research finding this closes: the vendored `:a2a` 0.2.0 dependency ships
  no `test/` directory at all, and `ash_a2a` itself never wires any
  `AshA2A.Protocol.Plug`/HTTP transport (it only documents the contract a caller's
  separately-wired Plug pipeline is expected to satisfy) -- so before this
  test, nothing in either codebase proved `AshA2A.Protocol.Plug.serve_agent_card/2`
  actually serves a real `AshA2A`-compiled agent card over real HTTP.
  `:plug` was previously only an *optional* dependency of `:a2a`
  (`~/xaas/deps/a2a/mix.exs:43`) that this project's `mix.exs` never pulled
  in -- `Code.ensure_loaded?(AshA2A.Protocol.Plug)` was `false` and the module did not
  exist at all prior to this change. `mix.exs` now declares
  `{:plug, "~> 1.16", only: :test}` so this real HTTP surface can actually be
  exercised, instead of being reported as infeasible-and-skipped.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the agent is a real
  `GenServer` process, `AshA2A.Protocol.Plug.call/2` is the real, unmodified `:a2a`
  Plug implementation, and the HTTP conn is a real `Plug.Test.conn/3`
  struct run through `Plug.run/2`-equivalent direct `call/2` invocation
  (the standard way to exercise a Plug without a real listening socket).
  """

  use ExUnit.Case, async: true

  alias AshA2A.Test.PlugFixture.{Greeter, GreeterAgent}

  setup do
    # Real per-test process name so parallel `async: true` test runs (and
    # other concurrently-running test files' own agents) never collide on
    # a single globally-registered GenServer name.
    agent_name = :"greeter_agent_#{System.unique_integer([:positive])}"
    {:ok, pid} = GreeterAgent.start_link(name: agent_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{agent: agent_name, pid: pid}
  end

  test "a real AshA2A.Protocol.Plug GET to the agent-card path serves the real AshA2A-compiled card", %{
    agent: agent
  } do
    base_url = "http://localhost:4000/a2a"

    plug_opts =
      AshA2A.Protocol.Plug.init(
        agent: agent,
        base_url: base_url
      )

    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    served_card = Jason.decode!(conn.resp_body)

    # The real, independently-computed expectation: build the agent card
    # straight from `AshA2A.Info.agent_card/2` (the same compiled
    # capability index `AshA2A.Agent.__card_opts__/2` feeds into
    # `use AshA2A.Protocol.Agent, ...` when `GreeterAgent` was compiled) and encode it
    # with the real `:a2a` JSON encoder the same way `AshA2A.Protocol.Plug` does
    # internally (`~/xaas/deps/a2a/lib/a2a/plug.ex:172-181`).
    expected_card = AshA2A.Info.agent_card(Greeter, name: "greeter_agent")

    expected_json =
      AshA2A.Protocol.JSON.encode_agent_card(expected_card, url: base_url)
      |> Jason.encode!()
      |> Jason.decode!()

    assert served_card == expected_json

    # And concretely assert the real skill made it through the real HTTP
    # response body, not just structural equality with another computed
    # value.
    # Real current shape (fbc3213 "derive canonical skills from public Ash
    # actions"): `id` is the fully-qualified "<Resource>.<action>" identity
    # (avoids collisions across resources sharing a short skill name);
    # `name` carries the short, declared skill name instead.
    assert %{
             "skills" => [
               %{"id" => "AshA2A.Test.PlugFixture.Greeter.read", "name" => "greet"}
             ]
           } = served_card

    # v1.0 wire shape (spec §4.4/8.2, single source of truth
    # `AshA2A.Protocol.Version.protocol_version/0`): the top-level `url` and
    # `protocolVersion` fields are GONE from the card — the base URL and the
    # protocol version ride only inside `supportedInterfaces` entries, and a
    # card-carried `supported_interfaces` entry (from the capability index)
    # takes precedence over the serving `:url` override.
    refute Map.has_key?(served_card, "url")
    refute Map.has_key?(served_card, "protocolVersion")

    assert %{
             "supportedInterfaces" => [
               %{"url" => _index_url, "protocolVersion" => "1.0"} | _
             ]
           } = served_card
  end

  test "a real AshA2A.Protocol.Plug GET to the agent-card path with no base_url raises ArgumentError", %{
    agent: agent
  } do
    # `serve_agent_card/2`'s real, documented behavior
    # (`~/xaas/deps/a2a/lib/a2a/plug.ex:166-170`): with no `base_url`
    # configured anywhere, it raises rather than silently serving a
    # URL-less card.
    plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: nil)

    assert_raise ArgumentError, ~r/requires a base_url/, fn ->
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> AshA2A.Protocol.Plug.call(plug_opts)
    end
  end

  test "a real AshA2A.Protocol.Plug POST to the agent-card path is rejected with 405", %{agent: agent} do
    plug_opts = AshA2A.Protocol.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

    conn =
      Plug.Test.conn(:post, "/.well-known/agent-card.json", "")
      |> AshA2A.Protocol.Plug.call(plug_opts)

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end
end
