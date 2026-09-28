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

  @moduletag :serial
  @moduletag :serial_shard
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
    %{pid: pid, base_url: base_url} = AshA2A.Test.EphemeralHttp.start!(MicroBeamOcelIngest)

    on_exit(fn ->
      Process.exit(pid, :normal)
      stop_named_agent(MicroBeamOcelIngest.Store)
    end)

    base_url
  end

  # The Agents above are `start_link`ed to the test process, so they begin
  # dying the moment the test process exits -- concurrently with this
  # `on_exit/1` callback, which ExUnit runs in a separate process afterwards.
  # A bare `if Process.whereis(name), do: Agent.stop(name)` is therefore a
  # real time-of-check/time-of-use race: `whereis` can see the dying Agent
  # and `Agent.stop/1` then exits with `:noproc` (observed, reproducible under
  # `mix test --seed 162937`). Stop by pid, tolerate it already being gone,
  # and wait for the real `:DOWN` so the name is unregistered before the next
  # test's `Agent.start_link(name: ...)` can run.
  defp stop_named_agent(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      agent ->
        ref = Process.monitor(agent)

        try do
          Agent.stop(agent)
        catch
          :exit, _already_gone -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^agent, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  defmodule SlowMicroBeamOcelIngest do
    @moduledoc """
    Real Plug.Router mirroring `MicroBeamOcelIngest` above, but the
    `POST /ocel/events` handler is GATED: it notifies the owning test
    process (pid read from a real Agent) that it is holding the request,
    then blocks until that test sends `:release` -- a real slow ingest
    endpoint whose slowness is controlled by the test, not by a wall-clock
    sleep (TQ-12: no race between a fixed server delay and the dispatch
    duration).
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      owner = Agent.get(SlowMicroBeamOcelIngest.Owner, & &1)
      send(owner, {:slow_ingest_request_held, self()})

      receive do
        :release -> :ok
      after
        60_000 -> :ok
      end

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

  defp start_slow_ocel_ingest!(owner) do
    {:ok, _} = Agent.start_link(fn -> [] end, name: SlowMicroBeamOcelIngest.Store)
    {:ok, _} = Agent.start_link(fn -> owner end, name: SlowMicroBeamOcelIngest.Owner)
    %{pid: pid, base_url: base_url} = AshA2A.Test.EphemeralHttp.start!(SlowMicroBeamOcelIngest)

    on_exit(fn ->
      Process.exit(pid, :normal)

      stop_named_agent(SlowMicroBeamOcelIngest.Store)
      stop_named_agent(SlowMicroBeamOcelIngest.Owner)
    end)

    base_url
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

  # `:next_phase` is a `:change` skill, so it reaches the dispatcher only
  # through the real `AshA2A.CommandBus` (sole-DO fence, `AshA2A.BrceAnchor`);
  # the forwarder merges the dispatch span into the one receipt event.
  test "a real :next_phase dispatch forwards a real, non-empty OCEL relationships entry naming the real plan instance" do
    plan_name = :"ocel_forwarder_relationships_test_#{System.unique_integer([:positive])}"

    message =
      Message.new_user([
        Part.Data.new(%{plan_name: plan_name, prompt_text: "next real phase, please"})
      ])

    assert {:reply, _parts} =
             AshA2A.Test.ReceiptedDispatch.dispatch(
               :next_phase,
               message,
               Facilitator,
               [],
               nil
             )

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["skill_name"] == "next_phase"
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

  test "a real dispatch against a slow OCEL ingest endpoint returns while the endpoint is still holding the POST, proving the POST is truly offloaded" do
    # Real gated HTTP server: the /ocel/events handler holds the request
    # until this test releases it. Before the async offload, `post_event/2`'s
    # `Req.post/2` executed synchronously inside `handle_event/4`, which
    # `:telemetry.span/3` (`dispatcher.ex:137`) runs synchronously in the
    # calling process -- so `AshA2A.Dispatcher.dispatch/5` itself would have
    # blocked until the response. In the real single-mailbox `A2A.Agent`
    # GenServer (`agent.ex`), that means every other caller queued behind it
    # would have blocked too.
    #
    # TQ-12: no wall-clock margin decides this test. The client
    # `receive_timeout` is raised to 60s, so a synchronous (regressed) POST
    # could not return the dispatch call before the 60s timeout; the dispatch
    # is given 10s to return while the server is provably still holding the
    # request (Store empty, response not sent). A 50x gap, not a 100ms one.
    previous_timeout = Application.get_env(:ash_a2a, :ocel_ingest_timeout_ms)
    Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, 60_000)

    on_exit(fn ->
      if previous_timeout,
        do: Application.put_env(:ash_a2a, :ocel_ingest_timeout_ms, previous_timeout),
        else: Application.delete_env(:ash_a2a, :ocel_ingest_timeout_ms)
    end)

    slow_url = start_slow_ocel_ingest!(self())
    Application.put_env(:ash_a2a, :ocel_ingest_url, slow_url)

    message =
      Message.new_user([
        Part.Data.new(%{
          "phase" => :trust_god,
          "prompt_text" => "must not block on a slow OCEL ingest endpoint"
        })
      ])

    dispatch = Task.async(fn -> AshA2A.Dispatcher.dispatch(:run_phase, message, Facilitator) end)

    assert {:ok, {:reply, _parts}} = Task.yield(dispatch, 10_000),
           "the dispatch call did not return while the OCEL endpoint was still holding " <>
             "the POST -- the POST is not actually offloaded"

    # The POST really reached the endpoint and is still being held: the
    # dispatch returned before any response existed.
    assert_receive {:slow_ingest_request_held, handler}, 10_000
    assert Agent.get(SlowMicroBeamOcelIngest.Store, & &1) == []

    send(handler, :release)

    # The event still eventually arrives -- offloading to a Task never drops
    # it, only defers the network call off the calling process.
    events = wait_for_slow_events(1, 10_000)

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
