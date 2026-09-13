defmodule AshA2A.PlugAgentCardTest do
  @moduledoc """
  Real, end-to-end test for assignment #3 (ash_a2a A2A.Plug agent-card
  serving hardening): fronts a real, running `AshA2A.Agent`-generated
  `A2A.Agent` GenServer (`AshA2A.Test.PlugFixture.GreeterAgent`) with a real
  `A2A.Plug`, drives a real `Plug.Test` GET request against the well-known
  agent-card path, and asserts the real HTTP response body matches what
  `AshA2A.Info.agent_card/2` + `A2A.JSON.encode_agent_card/2` produce
  directly from the same compiled capability index.

  Research finding this closes: the vendored `:a2a` 0.2.0 dependency ships
  no `test/` directory at all, and `ash_a2a` itself never wires any
  `A2A.Plug`/HTTP transport (it only documents the contract a caller's
  separately-wired Plug pipeline is expected to satisfy) -- so before this
  test, nothing in either codebase proved `A2A.Plug.serve_agent_card/2`
  actually serves a real `AshA2A`-compiled agent card over real HTTP.
  `:plug` was previously only an *optional* dependency of `:a2a`
  (`~/xaas/deps/a2a/mix.exs:43`) that this project's `mix.exs` never pulled
  in -- `Code.ensure_loaded?(A2A.Plug)` was `false` and the module did not
  exist at all prior to this change. `mix.exs` now declares
  `{:plug, "~> 1.16", only: :test}` so this real HTTP surface can actually be
  exercised, instead of being reported as infeasible-and-skipped.

  No `Mock`/`mox`/`patch`/`monkeypatch` anywhere: the agent is a real
  `GenServer` process, `A2A.Plug.call/2` is the real, unmodified `:a2a`
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

  test "a real A2A.Plug GET to the agent-card path serves the real AshA2A-compiled card", %{
    agent: agent
  } do
    base_url = "http://localhost:4000/a2a"

    plug_opts =
      A2A.Plug.init(
        agent: agent,
        base_url: base_url
      )

    conn =
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> A2A.Plug.call(plug_opts)

    assert conn.status == 200
    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    served_card = Jason.decode!(conn.resp_body)

    # The real, independently-computed expectation: build the agent card
    # straight from `AshA2A.Info.agent_card/2` (the same compiled
    # capability index `AshA2A.Agent.__card_opts__/2` feeds into
    # `use A2A.Agent, ...` when `GreeterAgent` was compiled) and encode it
    # with the real `:a2a` JSON encoder the same way `A2A.Plug` does
    # internally (`~/xaas/deps/a2a/lib/a2a/plug.ex:172-181`).
    expected_card = AshA2A.Info.agent_card(Greeter, name: "greeter_agent")

    expected_json =
      A2A.JSON.encode_agent_card(expected_card, url: base_url)
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

    assert served_card["url"] == base_url
  end

  test "a real A2A.Plug GET to the agent-card path with no base_url raises ArgumentError", %{
    agent: agent
  } do
    # `serve_agent_card/2`'s real, documented behavior
    # (`~/xaas/deps/a2a/lib/a2a/plug.ex:166-170`): with no `base_url`
    # configured anywhere, it raises rather than silently serving a
    # URL-less card.
    plug_opts = A2A.Plug.init(agent: agent, base_url: nil)

    assert_raise ArgumentError, ~r/requires a base_url/, fn ->
      Plug.Test.conn(:get, "/.well-known/agent-card.json")
      |> A2A.Plug.call(plug_opts)
    end
  end

  test "a real A2A.Plug POST to the agent-card path is rejected with 405", %{agent: agent} do
    plug_opts = A2A.Plug.init(agent: agent, base_url: "http://localhost:4000/a2a")

    conn =
      Plug.Test.conn(:post, "/.well-known/agent-card.json", "")
      |> A2A.Plug.call(plug_opts)

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end
end
