# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Telemetry.OcelDispatchParityTest do
  @moduledoc """
  The forwarder (HTTP) and the broadcaster (SIEM) must emit the SAME dispatch
  event for the same telemetry: both are built by
  `AshA2A.Telemetry.DispatchEvent`. Real telemetry -> two real sinks (a real
  Bandit forwarder ingest and a real Bandit Chronicle receiver) -> compare
  the wire bodies (modulo `event_id`/`event_time`). Also pins the forwarder's
  handler hygiene: a hostile metadata shape neither raises nor detaches it,
  and a stale CommandBus dispatch stash is never merged into an unrelated
  receipt.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Telemetry.{DispatchEvent, OcelBroadcaster, OcelForwarder}

  @resource AshA2A.Test.Fixture.FreedomGym.Facilitator
  @store AshA2A.Telemetry.OcelDispatchParityTest.Store

  defmodule Receiver do
    @moduledoc false
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    # forwarder ingest (JSON {"events": [...]}) and Chronicle (ndjson) in one
    post "/ocel/events" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"events" => events} = Jason.decode!(body)
      Agent.update(AshA2A.Telemetry.OcelDispatchParityTest.Store, &(&1 ++ [{:http, events}]))
      Plug.Conn.send_resp(conn, 201, "{}")
    end

    post "/v2/logs" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      events =
        body |> String.split("\n") |> Enum.reject(&(&1 == "")) |> Enum.map(&Jason.decode!/1)

      Agent.update(AshA2A.Telemetry.OcelDispatchParityTest.Store, &(&1 ++ [{:siem, events}]))
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    match(_) do
      Plug.Conn.send_resp(conn, 404, "no")
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @store)
    %{base_url: base_url, pid: pid} = AshA2A.Test.EphemeralHttp.start!(Receiver)
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = OcelForwarder.attach!()

    name = :"ocel_parity_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OcelBroadcaster,
       name: name,
       endpoints: [[platform: :chronicle, endpoint: base_url, api_key: "k", max_retries: 0]],
       flush_interval_ms: false}
    )

    on_exit(fn ->
      Process.exit(pid, :normal)
      OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
      Application.delete_env(:ash_a2a, :ocel_pending_dispatch_ttl_ms)
    end)

    {:ok, bc: name}
  end

  # The one bounded poll: a deadline, not an iteration count.
  defp poll(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(10)
          poll(fun, deadline)
        end

      result ->
        result
    end
  end

  defp wire(kind) do
    poll(fn ->
      case for {^kind, evs} <- Agent.get(@store, & &1), do: evs do
        [] -> nil
        lists -> List.flatten(lists)
      end
    end)
  end

  defp normalise(event), do: Map.drop(event, ["event_id", "event_time"])

  defp parity!(bc, event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)

    assert :ok = OcelBroadcaster.flush(bc)
    [http] = wire(:http)
    [siem] = wire(:siem)

    assert normalise(http) == normalise(siem)
    assert http["event_time"] && siem["event_time"]
    http
  end

  test "dispatch stop with stage/error: identical attributes on both sinks", %{bc: bc} do
    event =
      parity!(bc, [:ash_a2a, :dispatch, :stop], %{duration: 77}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase,
        stage: :skill_lookup,
        error: %{kind: :unknown_skill},
        object_id: "obj-1"
      })

    assert event["attributes"]["stage"] == "skill_lookup"
    assert event["attributes"]["error"] == "unknown_skill"
    assert event["relationships"] == [%{"qualifier" => "acted_on", "object_id" => "obj-1"}]
  end

  test "dispatch exception: identical kind/error_code form on both sinks", %{bc: bc} do
    event =
      parity!(bc, [:ash_a2a, :dispatch, :exception], %{duration: 5}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase,
        kind: :error,
        reason: %RuntimeError{message: "secret"},
        stacktrace: []
      })

    assert event["event_type"] =~ ".exception"
    assert event["attributes"]["error_code"] == "exception:RuntimeError"
    refute inspect(event) =~ "secret"
  end

  test "DispatchEvent.event_type/1 is total over hostile metadata" do
    assert is_binary(DispatchEvent.event_type(%{}))
    assert is_binary(DispatchEvent.event_type(%{resource_or_domain: "str", skill_name: {:a, :b}}))
    assert is_binary(DispatchEvent.event_type(%{resource_or_domain: 42, skill_name: nil}))
    assert is_binary(DispatchEvent.event_type(:not_a_map))
  end

  test "the forwarder handler survives hostile metadata and stays attached" do
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
      resource_or_domain: "not-a-resource",
      skill_name: %{weird: true}
    })

    :telemetry.execute([:ash_a2a, :dispatch, :exception], %{}, %{resource_or_domain: 7})
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{}, %{})

    attached =
      for h <- :telemetry.list_handlers([:ash_a2a, :dispatch]),
          match?({OcelForwarder, _}, h.id),
          do: h.id

    assert length(attached) == 2
    assert [_ | _] = wire(:http)
  end

  test "unconvertible receipt metadata is counted by the forwarder" do
    before_count = OcelForwarder.unconvertible_count()
    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: :nope})
    :telemetry.execute([:ash_a2a, :receipt, :outboxed], %{}, %{})
    assert OcelForwarder.unconvertible_count() == before_count + 2
  end

  describe "pending dispatch stash" do
    defp receipt(command_id) do
      command =
        AshA2A.Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: command_id,
          agent_id: "agent-1",
          principal_id: "principal-1"
        )

      AshA2A.Receipt.from_reply(
        command,
        AshA2A.Identity.execution("exec-#{command_id}"),
        :observe,
        {:reply, []}
      )
    end

    defp stash_dispatch(extra) do
      Process.put(:ash_a2a_ocel_command_bus_dispatch, true)

      :telemetry.execute(
        [:ash_a2a, :dispatch, :stop],
        %{duration: 9},
        Map.merge(
          %{resource_or_domain: @resource, skill_name: :run_phase, reply_type: :reply},
          extra
        )
      )

      Process.delete(:ash_a2a_ocel_command_bus_dispatch)
    end

    test "a fresh stash for the same command merges into the receipt event" do
      stash_dispatch(%{command_id: "cmd-fresh", object_id: "obj-9"})
      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt("cmd-fresh")})

      [event] = wire(:http)
      assert event["attributes"]["skill_name"] == "run_phase"
      assert event["relationships"] == [%{"qualifier" => "acted_on", "object_id" => "obj-9"}]
    end

    test "a stale stash (past the TTL) is discarded, not merged into an unrelated receipt" do
      # A negative TTL makes every stash stale at consumption time.
      Application.put_env(:ash_a2a, :ocel_pending_dispatch_ttl_ms, -1)
      stash_dispatch(%{object_id: "stale-obj"})

      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{
        receipt: receipt("cmd-unrelated")
      })

      [event] = wire(:http)
      refute Map.has_key?(event["attributes"], "skill_name")
      assert event["relationships"] == []
      # and the stash is cleared
      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end

    test "a stash for a DIFFERENT command is discarded" do
      stash_dispatch(%{command_id: "cmd-A", object_id: "obj-A"})
      :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt("cmd-B")})

      [event] = wire(:http)
      refute Map.has_key?(event["attributes"], "skill_name")
      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end

    test "a direct dispatch clears a leftover stash" do
      stash_dispatch(%{object_id: "leftover"})
      assert Process.get(:ash_a2a_ocel_pending_dispatch)

      :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
        resource_or_domain: @resource,
        skill_name: :run_phase
      })

      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end
  end
end
