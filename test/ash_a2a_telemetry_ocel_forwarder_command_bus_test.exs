defmodule AshA2A.Telemetry.OcelForwarderCommandBusTest do
  @moduledoc """
  Chicago-school test proving the real fix for the disclosed OCEL
  double-event-emission defect on CommandBus-routed dispatch: before this
  fix, `AshA2A.CommandBus.run/4` internally called
  `AshA2A.Dispatcher.dispatch/5` (`command_bus.ex`), whose own
  `:telemetry.span([:ash_a2a, :dispatch], ...)` (`dispatcher.ex:137`) fired
  `[:ash_a2a, :dispatch, :stop]` unconditionally, AND `CommandBus.run/4`
  separately fired `[:ash_a2a, :receipt, :committed]`
  (`command_bus.ex#emit_receipt/1`) after every commit -- and
  `AshA2A.Telemetry.OcelForwarder` had independent handlers on both events,
  each independently POSTing its own OCEL v2 event to the real ingest
  endpoint, so one CommandBus-routed dispatch produced two OCEL events for
  one logical command.

  Reuses this file's sibling `AshA2A.Telemetry.OcelForwarderTest`'s real
  Bandit `MicroBeamOcelIngest` fixture pattern and the same real FreedomGym
  `Facilitator` fixture's `:next_phase` skill (already used there, giving a
  real non-nil `object_id`/`relationships` to verify survive the merge) --
  no mocks, a real Bandit HTTP listener, a real `Req.post`, a real captured
  HTTP request body asserted on directly.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  defmodule MicroBeamOcelIngest do
    @moduledoc """
    Same minimal real `Plug.Router` shape as
    `AshA2A.Telemetry.OcelForwarderTest.MicroBeamOcelIngest` -- duplicated
    (not shared/aliased) so this test file's real Bandit listener and Agent
    store are fully independent of the sibling test file's, avoiding any
    cross-file process-naming collision under `async: false`.
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(MicroBeamOcelIngest.Store, fn acc -> acc ++ events end)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"ok" => true, "accepted" => events}))

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            422,
            Jason.encode!(%{"ok" => false, "error" => "expected events list"})
          )
      end
    end

    match(_) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        404,
        Jason.encode!(%{"ok" => false, "error" => "route_not_admitted"})
      )
    end
  end

  defp start_micro_beam_ocel_ingest! do
    {:ok, _} = Agent.start_link(fn -> [] end, name: MicroBeamOcelIngest.Store)
    port = Enum.random(23_000..23_999)
    {:ok, pid} = Bandit.start_link(plug: MicroBeamOcelIngest, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)
      if Process.whereis(MicroBeamOcelIngest.Store), do: Agent.stop(MicroBeamOcelIngest.Store)
    end)

    "http://127.0.0.1:#{port}"
  end

  setup do
    base_url = start_micro_beam_ocel_ingest!()
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
    end)

    {:ok, base_url: base_url, store_opts: [name: name]}
  end

  test "a real CommandBus-routed :next_phase dispatch produces exactly ONE OCEL event, carrying both receipt and dispatch evidence",
       %{store_opts: store_opts} do
    plan_name = :"ocel_dedupe_command_bus_test_#{System.unique_integer([:positive])}"
    capability_id = "AshA2A.Test.Fixture.FreedomGym.Facilitator.next_phase"
    principal = Identity.principal("subject-1")
    authority = Authority.new(principal, capability_id, token_id: "auth-next-phase-1")

    command =
      Command.new(capability_id,
        command_id: "next-phase-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{plan_name: plan_name, prompt_text: "next real phase, please"}
      )

    message = data_message(%{plan_name: plan_name, prompt_text: "next real phase, please"})

    assert {:ok, receipt} =
             CommandBus.run(command, message, Facilitator, store_opts: store_opts)

    assert receipt.status == :completed
    assert receipt.consequence == :change

    # Before the fix, two events would have landed here (one from the raw
    # `[:ash_a2a, :dispatch, :stop]` span, one from
    # `[:ash_a2a, :receipt, :committed]`) -- this proves exactly one does.
    events = wait_for_events(1, 2_000)
    assert [event] = events

    # Receipt-derived evidence (from `AshA2A.SemanticProjection.ocel_event/1`)
    # is preserved.
    assert event["attributes"]["command_id"] == Identity.external(receipt.command_id)
    assert event["attributes"]["capability_id"] == capability_id
    assert event["attributes"]["status"] == "completed"

    # Dispatch-derived evidence (from the raw `[:ash_a2a, :dispatch, :stop]`
    # span this fix merges in rather than discards) is also preserved: the
    # real object-identity relationship naming the real plan instance, and
    # the real dispatch duration.
    assert [%{"qualifier" => "acted_on", "object_id" => object_id}] = event["relationships"]
    assert object_id == Atom.to_string(plan_name)
    assert event["attributes"]["duration_native"]
    assert event["attributes"]["skill_name"] == "next_phase"
  end

  defp wait_for_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(min_count, deadline)
  end

  defp poll_until(min_count, deadline) do
    events = Agent.get(MicroBeamOcelIngest.Store, & &1)

    cond do
      length(events) >= min_count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        poll_until(min_count, deadline)
    end
  end
end
