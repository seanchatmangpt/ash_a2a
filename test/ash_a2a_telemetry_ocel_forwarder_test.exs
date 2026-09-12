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

    # Real HTTP forwarding is fire-and-forget inside the telemetry handler
    # (Req.post is synchronous within handle_event/4, but give the handler
    # a real, generous window in case of scheduling jitter rather than
    # asserting on the very next line with zero tolerance).
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

  test "a real refused dispatch (unknown skill) still produces real OCEL evidence -- refusals are first-class" do
    message = Message.new_user([Part.Data.new(%{})])

    assert {:error, {:skill_lookup, {:unknown_skill, :not_a_real_skill}}} =
             AshA2A.Dispatcher.dispatch(:not_a_real_skill, message, Facilitator)

    events = wait_for_events(1, 2_000)

    assert [event] = events
    assert event["attributes"]["stage"] == "skill_lookup"
    assert event["attributes"]["error"] =~ "unknown_skill"
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
