defmodule AshA2A.PartisanIntegrationTest do
  @moduledoc """
  Real-attempted, real-BLOCKED investigation spike (v26.9.16,
  `feat/partisan-investigate-v26.9.16`): whether Partisan (Meiklejohn et
  al., building on the USENIX ATC 2019-era distributed-Erlang full-mesh
  clustering-ceiling work) can be integrated into this repo to replace or
  augment `:global`/`net_kernel` clustering beyond its documented
  ~dozens-to-~200-node ceiling.

  This is NOT a mock, NOT a stub, and NOT a passing test dressed up as a
  real one -- per `~/.claude/rules/testing-chicago-style.md` this repo does
  not fake collaborators. It is the opposite: an honest `@tag :skip` over a
  real intended two-node join/message test, left unskippable-to-green
  because the real blocker (Hex dependency resolution) was never cleared.

  Real, verbatim blocking error (`mix deps.get`, this session, this
  worktree, with `{:partisan, "~> 6.2", only: :dev}` added to `mix.exs`):

      Resolving Hex dependencies...
      Resolution completed in 0.281s
      Because "oban >= 2.20.0" depends on "telemetry ~> 1.3" and "partisan >= 5.0.0-rc.8" depends on "telemetry ~> 1.1.0", "oban >= 2.20.0" is incompatible with "partisan >= 5.0.0-rc.8".
      And because "your app" depends on "oban ~> 2.24", "partisan >= 5.0.0-rc.8" is forbidden.
      So, because "your app" depends on "partisan ~> 6.2", version solving failed.
      ** (Mix) Hex dependency resolution failed

  Root cause: Partisan `6.2.0` (the current latest Hex release, confirmed
  via the real Hex API) hard-pins `telemetry ~> 1.1.0` (non-optional); this
  repo already requires `oban ~> 2.24`, which requires `telemetry ~> 1.3`
  (already locked here at `1.4.2`). Those ranges do not overlap. A second,
  independent conflict layer (Partisan's exact `opentelemetry_api 1.2.1` pin
  vs. this repo's transitive `tesla` -> `opentelemetry_semantic_conventions
  ~> 1.27` requirement) was also confirmed real via a diagnostic-only
  `telemetry` override attempt. Full evidence, both verbatim resolver
  failures, and the real Hex API requirement dumps live in
  `docs/archive/reports/partisan-integration-investigation.md`.

  Because dependency resolution never completes, Partisan was never added
  to this repo's real `mix.exs`/`mix.lock` (leaving both would permanently
  break `mix deps.get` for every future checkout of this branch), so
  `Partisan`/`partisan_peer_service`/etc. are not compiled, loaded, or
  callable here. The test below documents the exact real shape the
  integration was chartered to prove (two real local BEAM nodes, joined over
  Partisan's own overlay via `partisan:join/1`, one real message delivered
  via `partisan:cast_message/2`) and is `@tag :skip`ped for that named,
  disclosed reason -- never silently passing, never mocking Partisan's API
  to fake a green result.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :partisan_investigation

  @tag :skip
  @tag skip:
         "BLOCKED at mix deps.get -- see docs/archive/reports/partisan-integration-investigation.md " <>
           "(Partisan 6.2.0's non-optional `telemetry ~> 1.1.0` pin conflicts with this repo's " <>
           "already-required `oban ~> 2.24` -> `telemetry ~> 1.3`; a second conflict layer via " <>
           "Partisan's exact `opentelemetry_api 1.2.1` pin was also confirmed real)"
  test "two real local nodes join over Partisan's overlay and exchange one real message" do
    # Intended real shape, per Partisan's own real documented API
    # (partisan.hexdocs.pm, fetched this session -- not improvised):
    #
    #   {:ok, _} = Application.ensure_all_started(:partisan)
    #
    #   node_b_spec = %{
    #     name: :node_b,
    #     listen_addrs: [%{ip: {127, 0, 0, 1}, port: 10_201}],
    #     channels: %{data: %{parallelism: 1}}
    #   }
    #
    #   :ok = :partisan.join(node_b_spec)
    #
    #   :ok = :partisan.cast_message({:echo_server, :node_b}, {:ping, self()})
    #   assert_receive {:pong, _from}, 5_000
    #
    # None of the above executes: `:partisan` is not a compiled dependency
    # of this repo (see moduledoc). This test exists to name the target
    # shape honestly, not to claim it runs.
    flunk("unreachable -- Partisan dependency never resolved; see @tag :skip reason above")
  end
end
