# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Sim.MirrorTest do
  @moduledoc """
  The simulation server mirrors the served surface of ash_a2a, and the prover
  drives all of it over the real wire.

    * MIRROR: every item `AshA2A.Sim.Surface` derives from the library has at
      least one probe. A JSON-RPC method, HTTP+JSON route or gRPC RPC added to
      the library without a probe fails here.
    * PROOF: the prover runs against a real `AshA2A.Sim.Server` (real Bandit
      listeners, a real gRPC endpoint, a real webhook receiver, the ETS data
      layer) and no probe fails.
    * SKIPS: the probes that report `:skip` are exactly the allowlist below.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Sim.{Prover, Server, Surface}

  @moduletag timeout: 240_000
  @moduletag capture_log: true

  # Every probe allowed to report `:skip`, with the text its reason must carry.
  # A skip is a known library defect the prover observed; fixing the defect
  # turns the probe into a pass and this entry must then be removed.
  @allowed_skips %{}

  setup_all do
    {:ok, server} = Server.start_link()
    info = Server.info()
    results = Prover.run(info)

    on_exit(fn ->
      if Process.alive?(server), do: Server.stop(server)
    end)

    {:ok, info: info, results: results}
  end

  describe "mirror" do
    test "every surface item has at least one probe" do
      uncovered = Surface.uncovered(Prover.probes())

      assert uncovered == [],
             "served surface items with no probe:\n" <>
               Enum.map_join(uncovered, "\n", &"  #{&1.id} (from #{&1.source})")
    end

    test "every probe names a real surface item" do
      ids = MapSet.new(Surface.ids())

      strays =
        Prover.probes() |> Enum.map(& &1.surface) |> Enum.reject(&(&1 in ids)) |> Enum.uniq()

      assert strays == []
    end

    test "a surface item with no probe is reported" do
      [first | rest] = Prover.probes()
      remaining = Enum.reject(rest, &(&1.surface == first.surface))
      assert [%{id: id}] = Surface.uncovered(remaining)
      assert id == first.surface
    end

    test "the JSON-RPC inventory holds every method the transports route" do
      methods = Surface.items(:jsonrpc_method) |> Enum.map(& &1.name)
      aliases = Surface.items(:jsonrpc_alias) |> Enum.map(& &1.name)

      for method <- AshA2A.A2ATransport.Plug.canonical_methods() do
        assert method in methods
      end

      for {spelling, target} <- AshA2A.A2ATransport.Plug.method_aliases() do
        assert spelling in aliases
        assert Surface.alias_target(spelling) == target
      end

      assert "message/send" in methods
      assert "tasks/subscribe" in aliases
    end

    test "the gRPC inventory is the proto's service, and the generated stub agrees" do
      rpcs = Surface.items(:grpc_rpc) |> Enum.map(& &1.name) |> Enum.sort()

      generated =
        Lf.A2a.V1.A2AService.Service.__rpc_calls__()
        |> Enum.map(&(&1 |> elem(0) |> to_string()))
        |> Enum.sort()

      assert rpcs == generated

      for %{name: name} <- AshA2A.Transport.Grpc.Dispatch.methods() do
        assert name in rpcs
      end

      assert "SendLiveMessage" in rpcs
    end

    test "the HTTP+JSON inventory holds the documented routes and no 405 answers" do
      routes = Surface.items(:http_route) |> Enum.map(& &1.name)

      for route <- [
            "GET /.well-known/agent-card.json",
            "POST /message:send",
            "POST /message:stream",
            "POST /message:live",
            "GET /tasks",
            "GET /tasks/{id}",
            "POST /tasks/{id}:cancel",
            "GET /tasks/{id}:subscribe",
            "POST /tasks/{id}:subscribe",
            "POST /tasks/{id}/pushNotificationConfigs",
            "GET /tasks/{id}/pushNotificationConfigs",
            "GET /tasks/{id}/pushNotificationConfigs/{configId}",
            "DELETE /tasks/{id}/pushNotificationConfigs/{configId}",
            "GET /extendedAgentCard",
            "POST /agent"
          ] do
        assert route in routes
      end

      refute "GET /tasks/{id}:cancel" in routes
      refute "GET /message:send" in routes
      assert routes == Enum.uniq(routes)
    end

    test "the simulation resource covers every action type and consequence class" do
      index = AshA2A.Info.capability_index(AshA2A.Sim.Note)
      classes = Surface.items(:consequence) |> Enum.map(&String.to_existing_atom(&1.name))

      assert Enum.sort(classes) == Enum.sort(Enum.uniq(Enum.map(index, & &1.consequence)))

      types =
        for skill <- index,
            do: Ash.Resource.Info.action(AshA2A.Sim.Note, skill.action).type

      assert Enum.sort(Enum.uniq(types)) == [:action, :create, :destroy, :read, :update]
    end
  end

  describe "proof" do
    test "the server reports the ports it bound", %{info: info} do
      for key <- [:http_port, :grpc_port, :push_port] do
        assert is_integer(info[key]) and info[key] > 0
      end

      assert info.jsonrpc_url == "http://127.0.0.1:#{info.http_port}/jsonrpc"
      assert info.grpc_target == "127.0.0.1:#{info.grpc_port}"
    end

    test "no probe fails", %{results: results} do
      failures = Enum.filter(results, &(&1.status == :fail))

      assert failures == [],
             "failing probes:\n" <>
               Enum.map_join(failures, "\n", &"  #{&1.surface} | #{&1.probe}\n      #{&1.detail}")
    end

    test "every probe ran and reported a detail", %{results: results} do
      assert length(results) == length(Prover.probes())
      assert Enum.all?(results, &(is_binary(&1.detail) and &1.detail != ""))
      assert Enum.all?(results, &(&1.status in [:pass, :fail, :skip]))
    end

    test "the skipped probes are exactly the allowlist", %{results: results} do
      skipped = for %{status: :skip} = result <- results, do: result

      assert length(skipped) == map_size(@allowed_skips)

      for result <- skipped do
        reason = Map.get(@allowed_skips, {result.surface, result.probe})
        assert reason, "unexpected skip: #{result.surface} | #{result.probe}: #{result.detail}"
        assert result.detail =~ reason
      end
    end

    test "the summary counts the results", %{results: results} do
      summary = Prover.summary(results)
      assert summary.pass + summary.fail + summary.skip == length(results)
      assert summary.pass > 150
      assert Prover.format(results) =~ "SURFACE"
    end
  end
end
