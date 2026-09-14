defmodule AshA2A.Test.Fixture.OcelDefaultPathItemAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the existing
  `AshA2A.Test.Fixture.Item` fixture (real `:create`/`:update`/`:destroy`
  skills, `test/support/fixture.ex`) -- private to this test file.

  Deliberately a SEPARATE module from `AshA2A.Test.Fixture.ItemAgent` (defined
  in `test/ash_a2a_agent_command_bus_test.exs`) even though both wrap the same
  `Item` fixture: `mix test` compiles/requires every `*_test.exs` file into
  the same running node, and two top-level `defmodule` declarations with the
  same name would silently redefine one another depending on file load
  order. A distinct module name (and a distinct `name:`) keeps this file
  correct and deterministic regardless of what order ExUnit loads test files
  in.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Item,
    name: "ocel_default_path_item_agent"
end

defmodule AshA2A.OcelDefaultPathSinkTest do
  @moduledoc """
  Proves the FULL real chain this session wired together, end to end:

    real `A2A.Agent.call/3`
      -> `AshA2A.Agent.__dispatch__/3` (the DEFAULT dispatch path every
         generated agent uses -- no test-only bypass)
      -> real `AshA2A.CommandBus.run/4` (consequence `:change`/`:external_do`
         skills are routed here, per `agent.ex`'s own real routing logic,
         directly re-read as part of writing this test)
      -> real `AshA2A.Dispatcher.dispatch/5` (still invoked FROM INSIDE
         `CommandBus.run/4`, `command_bus.ex:32-38` -- so its own
         `:telemetry.span([:ash_a2a, :dispatch], ...)` still fires)
      -> real committed `AshA2A.Receipt` (`CommandBus.run/4`'s `:execute`
         branch commits to the real configured `AshA2A.ReceiptStore` and
         emits `[:ash_a2a, :receipt, :committed]`, `command_bus.ex:40-43,89-91`)
      -> real `AshA2A.Telemetry.OcelForwarder` handlers for BOTH of the above
         events (attached, per this session's change, from
         `AshA2A.Application.start/2` -- `lib/ash_a2a/application.ex:27` --
         not from any test-only bootstrap)
      -> real HTTP `POST /ocel/events` -> a real local Bandit server standing
         in for BeamPM's real OCEL ingest endpoint, same pattern
         `test/ash_a2a_telemetry_ocel_forwarder_test.exs` already established.

  No Mock/mox/patch/monkeypatch anywhere in this file: a real Bandit HTTP
  listener, a real Req.post (inside the real `OcelForwarder`), a real
  captured HTTP request body asserted on directly, and a real supervised
  `A2A.Agent` GenServer process driving a real `Ash.Resource` through a real
  ETS data layer.

  ## Disclosed duplication (see the first test below for the receipted
  assertion)

  `AshA2A.Agent.__dispatch__/3` routes a `:change`/`:external_do` skill
  through `CommandBus.run/4` ONLY -- it never calls `AshA2A.Dispatcher.
  dispatch/5` directly itself. But `CommandBus.run/4`'s own `:execute` branch
  calls `AshA2A.Dispatcher.dispatch/5` internally to actually perform the
  Ash action, and THAT call is what carries the pre-existing
  `:telemetry.span([:ash_a2a, :dispatch], ...)` instrumentation
  (`dispatcher.ex:137`). So one real consequence-bearing dispatch through the
  default agent path genuinely fires BOTH:

    * `[:ash_a2a, :dispatch, :stop]` (from the inner `Dispatcher.dispatch/5`
      call `CommandBus.run/4` makes)
    * `[:ash_a2a, :receipt, :committed]` (from `CommandBus.run/4` itself,
      after the receipt is committed)

  Both are attached to `AshA2A.Telemetry.OcelForwarder`, and both forward to
  the SAME configured `:ocel_ingest_url` -- so the real sink below receives
  TWO real HTTP-POSTed OCEL events for one logical create, not one. This is
  a real, disclosed duplication of the resulting OCEL event stream (one
  low-level dispatch-span event, one higher-level receipt event, both
  genuinely fired, neither a bug in this test) -- proven directly below by
  asserting `length(events) == 2` and asserting on the real distinguishing
  content of each event, rather than silently asserting on `[event]` and
  hiding the duplicate.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.OcelDefaultPathItemAgent

  defmodule MicroBeamOcelIngest do
    @moduledoc """
    Minimal real `Plug.Router` mirroring beam4pm's actual
    `BeamPM.OcelIngest.Router` contract for `POST /ocel/events` only,
    identical in shape to
    `AshA2A.Telemetry.OcelForwarderTest.MicroBeamOcelIngest` -- duplicated
    (not shared) so this file's Bandit server/port/Agent-store lifecycle is
    fully independent of the other test file's, since both run `async: false`
    and could otherwise race on a shared named `Agent`.
    """
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["application/json"])
    plug(:match)
    plug(:dispatch)

    post "/ocel/events" do
      case conn.body_params do
        %{"events" => events} when is_list(events) ->
          Agent.update(OcelDefaultPathSinkStore, fn acc -> acc ++ events end)

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
    {:ok, _} = Agent.start_link(fn -> [] end, name: OcelDefaultPathSinkStore)
    port = Enum.random(23_000..23_999)
    {:ok, pid} = Bandit.start_link(plug: MicroBeamOcelIngest, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      Process.exit(pid, :normal)
      if Process.whereis(OcelDefaultPathSinkStore), do: Agent.stop(OcelDefaultPathSinkStore)
    end)

    "http://127.0.0.1:#{port}"
  end

  # `A2A.Plug` only populates `context.metadata["a2a.auth"]` after real
  # credential verification -- see the identical helper and citation in
  # `test/ash_a2a_agent_command_bus_test.exs`.
  defp authenticated_call_opts(identity) do
    [metadata: %{"a2a.auth" => %{identity: identity}}]
  end

  setup do
    base_url = start_micro_beam_ocel_ingest!()
    Application.put_env(:ash_a2a, :ocel_ingest_url, base_url)

    # Idempotent-safe (`{:error, :already_exists} -> :ok` inside `attach/2`).
    # `AshA2A.Application.start/2` already performs this exact call once, for
    # real, at initial `:ash_a2a` OTP application boot (verified directly by
    # reading `lib/ash_a2a/application.ex` before writing this test, and
    # re-proven by real execution in the dedicated
    # "Application.start/2 itself attaches..." test below) -- this call here
    # exists only so THIS test's outcome does not depend on whatever order
    # ExUnit happens to load test files in, since another `async: false` test
    # file in this same shared VM (`ash_a2a_telemetry_ocel_forwarder_test.exs`)
    # legitimately calls `OcelForwarder.detach()` in its own `on_exit`.
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        OcelDefaultPathItemAgent
      ])

    on_exit(fn ->
      AshA2A.Telemetry.OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)
    end)

    {:ok, base_url: base_url}
  end

  test "a real create dispatched through the default CommandBus-wired A2A.Agent path lands real, receipt-derived OCEL events at the real sink (and the real duplicate dispatch-span event, disclosed)" do
    message =
      data_message(%{"label" => "ocel-default-path-widget"}, %{
        metadata: %{skill: "create_item"}
      })

    assert {:ok, task} =
             OcelDefaultPathItemAgent.call(
               OcelDefaultPathItemAgent,
               message,
               authenticated_call_opts("user-1")
             )

    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: created}]}] = task.artifacts
    assert created.id

    events = wait_for_events(2, 2_000)

    # -- Disclosed duplication: exactly 2 real events for 1 real dispatch --
    assert length(events) == 2

    dispatch_events =
      Enum.filter(events, &String.starts_with?(&1["event_type"], "ash_a2a.dispatch."))

    receipt_events =
      Enum.filter(events, &String.starts_with?(&1["event_type"], "ash_a2a.receipt."))

    assert length(dispatch_events) == 1
    assert length(receipt_events) == 1

    [dispatch_event] = dispatch_events
    [receipt_event] = receipt_events

    # -- The low-level dispatch-span event (AshA2A.Dispatcher, called FROM
    # INSIDE CommandBus.run/4) -----------------------------------------
    item_short_name = Ash.Resource.Info.short_name(AshA2A.Test.Fixture.Item)
    assert dispatch_event["event_type"] == "ash_a2a.dispatch.#{item_short_name}.create_item"
    assert dispatch_event["attributes"]["skill_name"] == "create_item"
    assert dispatch_event["attributes"]["reply_type"] == "reply"
    refute Map.has_key?(dispatch_event["attributes"], "stage")

    # -- The receipt-derived event: real content from the real committed
    # AshA2A.Receipt (AshA2A.SemanticProjection.ocel_event/1), not merely
    # "telemetry fired" -------------------------------------------------
    assert receipt_event["event_type"] == "ash_a2a.receipt.completed"
    assert receipt_event["event_id"]
    assert receipt_event["event_time"]
    assert receipt_event["attributes"]["capability_id"] == "create_item"
    assert receipt_event["attributes"]["consequence"] == "change"
    assert receipt_event["attributes"]["status"] == "completed"
    assert receipt_event["attributes"]["replayed"] == false
    assert is_binary(receipt_event["attributes"]["command_id"])
    assert is_binary(receipt_event["attributes"]["execution_id"])
    assert is_binary(receipt_event["attributes"]["fingerprint"])
    assert receipt_event["attributes"]["principal_id"] =~ "user-1"
  end

  test "a real update through the same default path also produces a real receipt-derived OCEL event with :change consequence" do
    create_message =
      data_message(%{"label" => "before-update"}, %{metadata: %{skill: "create_item"}})

    assert {:ok, create_task} =
             OcelDefaultPathItemAgent.call(
               OcelDefaultPathItemAgent,
               create_message,
               authenticated_call_opts("user-2")
             )

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: created}]}] = create_task.artifacts
    item_id = created.id

    # Drain the create's own real events (1 dispatch-span + 1 receipt) before
    # driving the update, so the assertions below are scoped to the update's
    # own real events only.
    _ = wait_for_events(2, 2_000)
    :ok = Agent.update(OcelDefaultPathSinkStore, fn _acc -> [] end)

    update_message =
      data_message(%{"id" => item_id, "label" => "after-update"}, %{
        metadata: %{skill: "update_item"}
      })

    assert {:ok, update_task} =
             OcelDefaultPathItemAgent.call(
               OcelDefaultPathItemAgent,
               update_message,
               authenticated_call_opts("user-2")
             )

    assert update_task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: updated}]}] = update_task.artifacts
    assert updated.label == "after-update"

    events = wait_for_events(2, 2_000)
    assert length(events) == 2

    [receipt_event] =
      Enum.filter(events, &String.starts_with?(&1["event_type"], "ash_a2a.receipt."))

    assert receipt_event["attributes"]["capability_id"] == "update_item"
    assert receipt_event["attributes"]["consequence"] == "change"
    assert receipt_event["attributes"]["status"] == "completed"
  end

  test "AshA2A.Application.start/2 itself really attaches the OCEL forwarder -- real re-execution of the exact boot path, not a source read" do
    # Detach first so this test genuinely observes attach/2's own effect
    # rather than residual state left by this file's own `setup` (or any
    # other test) having already attached it.
    AshA2A.Telemetry.OcelForwarder.detach()
    refute handler_attached?([:ash_a2a, :dispatch, :stop])
    refute handler_attached?([:ash_a2a, :receipt, :committed])

    # `AshA2A.Supervisor` is already running (started once, for real, at
    # initial `:ash_a2a` OTP application boot for this whole `mix test` run).
    # Calling `AshA2A.Application.start/2` again is therefore expected to
    # fail at its own final `Supervisor.start_link/2` step with
    # `{:error, {:already_started, _pid}}` -- but the real
    # `:ok = AshA2A.Telemetry.OcelForwarder.attach!()` line
    # (`lib/ash_a2a/application.ex:27`) executes BEFORE that
    # `Supervisor.start_link/2` call in the function body, so this is a
    # real, genuine re-execution of the exact attach step `start/2` performs
    # at real boot -- not a simulation, and not merely reading the source.
    assert {:error, {:already_started, _pid}} = AshA2A.Application.start(:normal, [])

    assert handler_attached?([:ash_a2a, :dispatch, :stop])
    assert handler_attached?([:ash_a2a, :receipt, :committed])
  end

  defp handler_attached?(event) do
    Enum.any?(:telemetry.list_handlers(event), fn %{id: id} ->
      id in [
        {AshA2A.Telemetry.OcelForwarder, :dispatch_stop},
        {AshA2A.Telemetry.OcelForwarder, :receipt_committed}
      ]
    end)
  end

  defp wait_for_events(min_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(min_count, deadline)
  end

  defp poll_until(min_count, deadline) do
    events = Agent.get(OcelDefaultPathSinkStore, & &1)

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
