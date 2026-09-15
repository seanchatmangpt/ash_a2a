defmodule AshA2A.Telemetry.OcelForwarderTest do
  @moduledoc """
  Chicago-school test: real `:telemetry` emission from `AshA2A.Dispatcher`'s
  own already-real `:telemetry.span([:ash_a2a, :dispatch], ...)`
  (dispatcher.ex:137-140), forwarded by the real
  `AshA2A.Telemetry.OcelForwarder` handler, landing at a REAL local HTTP
  server whose route/decode contract mirrors beam4pm's real, already-running
  `BeamPM.OcelIngest.Router` byte-for-byte (read directly from
  `~/beam4pm/lib/beam4pm_ocel_ingest.ex` before writing this fixture -- same
  `POST /ocel/events`, `{"events": [...]}`, `event_id`/`event_type`/
  `event_time`/`attributes` shape, same 201/422 status convention).

  Exercises a REAL FreedomGym fixture (`AshA2A.Test.Fixture.FreedomGym.
  Facilitator`, already-existing test capital, not invented for this test)
  dispatched through the real `AshA2A.Dispatcher.dispatch/5` -- proving the
  exact claim this module exists to satisfy: any real skill dispatch across
  any AshA2A-backed app (FreedomGym Chicago-core, LLM-backed avatars, the
  rap-battle integration, or real production A2A traffic) gets real OCEL v2
  visibility with zero new instrumentation at each call site, because the
  telemetry span already existed before this module was written.

  No mocks: a real Bandit HTTP listener, a real Req.post, a real captured
  HTTP request body, asserted on directly.
  """
  use ExUnit.Case, async: false

  alias A2A.Message
  alias A2A.Part
  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.Test.Fixture.FreedomGym.Facilitator

  defmodule MicroBeamOcelIngest do
    @moduledoc """
    Minimal real Plug.Router mirroring beam4pm's actual
    `BeamPM.OcelIngest.Router` contract for `POST /ocel/events` only (the
    one route this forwarder uses) -- captures the real decoded event(s)
    into a real Agent so the test can assert on exactly what arrived, real
    HTTP round trip, not a hand-decoded closure.
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
    port = Enum.random(22_000..22_999)
    {:ok, pid} = Bandit.start_link(plug: MicroBeamOcelIngest, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)
      if Process.whereis(MicroBeamOcelIngest.Store), do: Agent.stop(MicroBeamOcelIngest.Store)
    end)

    "http://127.0.0.1:#{port}"
  end

  defmodule SlowMicroBeamOcelIngest do
    @moduledoc """
    Real Plug.Router mirroring `MicroBeamOcelIngest` above, but the
    `POST /ocel/events` handler sleeps a real, configurable number of
    milliseconds (read from a real Agent, not hardcoded) before responding --
    a real slow ingest endpoint, not a simulated one, to prove the calling
    process is never held open for that long any more.
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      delay_ms = Agent.get(SlowMicroBeamOcelIngest.Delay, & &1)
      Process.sleep(delay_ms)

      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(SlowMicroBeamOcelIngest.Store, fn acc -> acc ++ events end)

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
  end

  defp start_slow_ocel_ingest!(delay_ms) do
    {:ok, _} = Agent.start_link(fn -> [] end, name: SlowMicroBeamOcelIngest.Store)
    {:ok, _} = Agent.start_link(fn -> delay_ms end, name: SlowMicroBeamOcelIngest.Delay)
    port = Enum.random(23_000..23_999)
    {:ok, pid} = Bandit.start_link(plug: SlowMicroBeamOcelIngest, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)

      if Process.whereis(SlowMicroBeamOcelIngest.Store),
        do: Agent.stop(SlowMicroBeamOcelIngest.Store)

      if Process.whereis(SlowMicroBeamOcelIngest.Delay),
        do: Agent.stop(SlowMicroBeamOcelIngest.Delay)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp wait_for_slow_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_slow_until(min_count, deadline)
  end

  defp poll_slow_until(min_count, deadline) do
    events = Agent.get(SlowMicroBeamOcelIngest.Store, & &1)

    cond do
      length(events) >= min_count ->
        events

      System.monotonic_time(:millisecond) >= deadline ->
        events

      true ->
        Process.sleep(25)
        poll_slow_until(min_count, deadline)
    end
  end

  setup do
    base_url = start_micro_beam_ocel_ingest!()
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
    end)

    {:ok, base_url: base_url}
  end

  test "a real AshA2A skill dispatch produces a real OCEL v2 event at the ingest endpoint" do
    message =
      Message.new_user([
        Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "Name one thing you trust today."
        })
      ])

    assert {:reply, _parts} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)

    # Real HTTP forwarding happens on a supervised `Task` the telemetry
    # handler starts and does not await, so give it a real, generous window
    # for the async POST to land rather than asserting on the very next line
    # with zero tolerance.
    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["event_type"] == "ash_a2a.dispatch.facilitator.run_phase"
    assert event["event_id"]
    assert event["event_time"]
    assert event["attributes"]["skill_name"] == "run_phase"
    assert event["attributes"]["reply_type"] == "reply"
    refute Map.has_key?(event["attributes"], "stage")
  end

  test "a real :next_phase dispatch forwards a real, non-empty OCEL relationships entry naming the real plan instance" do
    plan_name = :"ocel_forwarder_relationships_test_#{System.unique_integer([:positive])}"

    message =
      Message.new_user([
        Part.Data.new(%{plan_name: plan_name, prompt_text: "next real phase, please"})
      ])

    assert {:reply, _parts} =
             AshA2A.Dispatcher.dispatch(
               :next_phase,
               message,
               Facilitator,
               [],
               nil
             )

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["event_type"] == "ash_a2a.dispatch.facilitator.next_phase"
    assert [%{"qualifier" => "acted_on", "object_id" => object_id}] = event["relationships"]
    assert object_id == Atom.to_string(plan_name)
  end

  test "a real :run_phase dispatch (no real object identity available) forwards an empty relationships array, never a fabricated one" do
    message =
      Message.new_user([
        Part.Data.new(%{"phase" => :trust_god, "prompt_text" => "no plan_name here"})
      ])

    assert {:reply, _parts} = AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator)

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["relationships"] == []
  end

  test "a real receipt-committed event reached without a preceding CommandBus-routed dispatch span (receipt_event/1's nil-dispatch branch) still carries the relationships key" do
    # `AshA2A.Telemetry.OcelForwarder.receipt_event/1`'s nil branch is taken
    # whenever `[:ash_a2a, :receipt, :committed]` fires and
    # `Process.delete(:ash_a2a_ocel_pending_dispatch)` finds nothing stashed
    # -- exactly what `AshA2A.CommandBus.run/4`'s `emit_receipt/1` call is
    # real production shape of, and exactly what a direct (non-CommandBus)
    # committer of a receipt would also produce. Firing the exact same real
    # `:telemetry.execute/3` call `emit_receipt/1` makes, with a real
    # `%AshA2A.Receipt{}` built the same way
    # `AshA2A.SemanticProjectionTest` builds one, exercises this real branch
    # directly without going through CommandBus -- no mock, a real telemetry
    # dispatch to the real attached handler, landing at the real Bandit
    # ingest fixture.
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "nil-dispatch-branch-1",
        agent_id: "agent-1",
        principal_id: "principal-1"
      )

    receipt =
      Receipt.from_reply(
        command,
        Identity.execution("exec-nil-dispatch-1"),
        :observe,
        {:reply, []}
      )

    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt})

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["command_id"] == Identity.external(receipt.command_id)
    assert Map.has_key?(event, "relationships")
    assert event["relationships"] == []
  end

  test "a real refused dispatch (unknown skill) still produces real OCEL evidence -- refusals are first-class" do
    message = Message.new_user([Part.Data.new(%{})])

    assert {:error, {:skill_lookup, {:unknown_skill, :not_a_real_skill}}} =
             AshA2A.Dispatcher.dispatch(:not_a_real_skill, message, Facilitator)

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["stage"] == "skill_lookup"
    assert event["attributes"]["error"] =~ "unknown_skill"
  end

  test "a real dispatch against a slow OCEL ingest endpoint returns well before the slow response, proving the POST is truly offloaded" do
    # Real slow HTTP server: the /ocel/events handler really sleeps this long
    # before responding. Before the async offload, `post_event/2`'s
    # `Req.post/2` executed synchronously inside `handle_event/4`, which
    # `:telemetry.span/3` (`dispatcher.ex:137`) runs synchronously in the
    # calling process -- so `AshA2A.Dispatcher.dispatch/5` itself would have
    # blocked for this entire delay. In the real single-mailbox `A2A.Agent`
    # GenServer (`agent.ex`), that means every other caller queued behind it
    # would have blocked too.
    # Chosen below `post_event/2`'s default 2_000ms `receive_timeout_ms` so
    # the deferred POST still completes successfully (a real 201, not a
    # client-side transport timeout) -- isolating exactly the claim under
    # test: the calling process no longer waits for it.
    delay_ms = 800
    slow_url = start_slow_ocel_ingest!(delay_ms)
    Application.put_env(:ash_a2a, :ocel_ingest_url, slow_url)

    message =
      Message.new_user([
        Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "must not block on a slow OCEL ingest endpoint"
        })
      ])

    {elapsed_us, {:reply, _parts}} =
      :timer.tc(fn -> AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator) end)

    elapsed_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

    assert elapsed_ms < delay_ms,
           "expected the dispatch call to return well before the OCEL endpoint's " <>
             "#{delay_ms}ms response (and far before the old ~30s+ worst case), " <>
             "got #{elapsed_ms}ms -- the POST is not actually offloaded"

    # The event still eventually arrives -- offloading to a Task never drops
    # it, only defers the network call off the calling process.
    events = wait_for_slow_events(1, delay_ms + 1_500)

    assert [event] = events
    assert event["event_type"] == "ash_a2a.dispatch.facilitator.run_phase"
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
