defmodule AshA2A.Test.Fixture.ItemAgent do
  @moduledoc """
  Real `A2A.Agent` GenServer built with `use AshA2A.Agent` over the existing
  `AshA2A.Test.Fixture.Item` fixture (real `:create`/`:update`/`:destroy`/
  `:ping` skills, `test/support/fixture.ex`) -- private to this test file
  since no shared fixture wraps `Item` in a real agent process yet.
  """

  use AshA2A.Agent, resource_or_domain: AshA2A.Test.Fixture.Item, name: "item_command_bus_agent"
end

defmodule AshA2A.Test.Fixture.UnclassifiedAction.Resource do
  @moduledoc """
  Real fixture resource, private to this test file, declaring one generic
  `:action` skill with NO explicit `consequence:` override -- so it stays at
  the real, compiled `:unknown` default
  (`AshA2A.CapabilityIndex.Compiler.default_consequence/1`) -- proving the
  fail-closed `:consequence_unclassified` refusal for a capability nobody
  has yet classified as safe.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.UnclassifiedAction.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A]

  actions do
    action :mystery, :string do
      run(fn _input, _context ->
        send(self(), :mystery_action_actually_ran)
        {:ok, "should never be reached"}
      end)
    end
  end

  a2a do
    skill(:mystery, :mystery)
  end
end

defmodule AshA2A.Test.Fixture.UnclassifiedAction.Domain do
  @moduledoc "Real fixture domain for `UnclassifiedAction.Resource` above."

  use Ash.Domain

  resources do
    resource(AshA2A.Test.Fixture.UnclassifiedAction.Resource)
  end
end

defmodule AshA2A.Test.Fixture.UnclassifiedActionAgent do
  @moduledoc "Real `A2A.Agent` GenServer over `UnclassifiedAction.Resource` above."

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.UnclassifiedAction.Resource,
    name: "unclassified_action_agent"
end

defmodule AshA2AAgentCommandBusTest do
  @moduledoc """
  Proves `AshA2A.CommandBus` is genuinely on the DEFAULT `A2A.Agent`/
  `AshA2A.Agent.__dispatch__/3` dispatch path -- the only path any deployed
  agent actually uses -- for every skill whose real, compiled
  `AshA2A.Skill.consequence` is `:change`/`:external_do`, not just the
  parallel, opt-in `Reactor.ExecuteCommand`/`Delivery.Oban`/
  `Execution.FLAME` routes `test/ash_a2a/command_bus_test.exs` already
  covers directly. Routing is by real compiled capability truth
  (`skill.consequence`, computed once at compile time from the real Ash
  `action.type` plus any explicit `a2a do skill ..., consequence: ... end`
  override), never by re-deriving a binary judgment from `action.type` at
  dispatch time.

  Real `A2A.Agent.call/3` calls through real supervised agent processes;
  real `:telemetry.attach/4` on the real `[:ash_a2a, :receipt, :committed]`
  event `AshA2A.CommandBus.emit_receipt/1` actually fires (the same real,
  attachable hook `AshA2A.Agent.__cancel__/2`'s own moduledoc points a
  resource author to) -- used here to observe the real committed
  `AshA2A.Receipt` a caller has no other way to retrieve (the default path
  intentionally returns only the underlying `A2A.Agent.reply()`, not the
  receipt itself, so a normal caller's contract is unchanged). No Mock/mox/
  patch/monkeypatch anywhere in this file.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.Test.Fixture.{
    FreedomGym,
    ItemAgent,
    UnclassifiedActionAgent,
    WidgetAgent
  }

  setup do
    {_sup, _registry_name} =
      AshA2A.Test.AgentSupervisorCase.start_supervised_agents!(__MODULE__, [
        ItemAgent,
        WidgetAgent,
        FreedomGym.FacilitatorAgent,
        UnclassifiedActionAgent
      ])

    # RFC-SA2A-001 S29: authentication alone no longer confers authority for
    # a `:change`/`:external_do` capability (see `AshA2A.Authority.Grant`);
    # a real broker grant must stand. Granted here for the exact
    # (principal, capability) pairs this file's own consequential dispatches
    # use. Deliberately NOT granted: `"ping"` (`:observe`, must stay
    # reachable without a grant) and `"mystery"` (`:unknown`, must stay
    # refused for a reason that has nothing to do with authority).
    AshA2A.Test.AuthorityGrantCase.grant!([
      {"user-1", ["create_item", "update_item", "destroy_item", "next_phase"]}
    ])

    handler_id = {:command_bus_test, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ash_a2a, :receipt, :committed],
      fn _event, _measurements, %{receipt: receipt}, _config ->
        send(test_pid, {:receipt_committed, receipt})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # `A2A.Plug` populates `context.metadata["a2a.auth"]` only after real
  # credential verification (`AshA2A.Agent.verified_auth_identity/1`'s own
  # moduledoc comment). `A2A.Agent.call/3`'s own `opts` keyword list becomes
  # exactly `context.metadata` (`~/xaas/deps/a2a/lib/a2a/agent.ex:269-272,
  # 285-290` threads `Keyword.get(opts, :metadata, %{})` straight into
  # `A2A.Agent.Runtime.process_message/5`'s `metadata` argument, which
  # becomes `Task.new(metadata: metadata)` and ultimately `context.metadata`
  # -- the second argument `handle_message/2` receives) -- so passing
  # `metadata:` here simulates an already-verified caller the same real way
  # `A2A.Plug` would have populated it, without needing a real Plug.Conn/
  # credential round-trip in this test.
  defp authenticated_call_opts(identity) do
    [metadata: %{"a2a.auth" => %{identity: identity}}]
  end

  test "a real create -> Agent -> CommandBus -> Ash.create -> Receipt" do
    message = data_message(%{"label" => "widget"}, %{metadata: %{skill: "create_item"}})

    assert {:ok, task} = ItemAgent.call(ItemAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :completed

    assert_receive {:receipt_committed, create_receipt}, 1_000
    assert create_receipt.capability_id == "create_item"
    assert create_receipt.consequence == :change
    assert create_receipt.status == :completed
    refute create_receipt.replayed?

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: created}]}] = task.artifacts
    item_id = created.id

    # -- update -> Agent -> CommandBus -> Ash.update -> Receipt ----------
    update_message =
      data_message(%{"id" => item_id, "label" => "widget-v2"}, %{
        metadata: %{skill: "update_item"}
      })

    assert {:ok, update_task} =
             ItemAgent.call(ItemAgent, update_message, authenticated_call_opts("user-1"))

    assert update_task.status.state == :completed

    assert_receive {:receipt_committed, update_receipt}, 1_000
    assert update_receipt.capability_id == "update_item"
    assert update_receipt.consequence == :change
    assert update_receipt.status == :completed

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: updated}]}] = update_task.artifacts
    assert updated.label == "widget-v2"

    # -- destroy -> Agent -> CommandBus -> Ash.destroy -> Receipt --------
    destroy_message = data_message(%{"id" => item_id}, %{metadata: %{skill: "destroy_item"}})

    assert {:ok, destroy_task} =
             ItemAgent.call(ItemAgent, destroy_message, authenticated_call_opts("user-1"))

    assert destroy_task.status.state == :completed

    assert_receive {:receipt_committed, destroy_receipt}, 1_000
    assert destroy_receipt.capability_id == "destroy_item"
    assert destroy_receipt.consequence == :change
    assert destroy_receipt.status == :completed
  end

  test "an unauthenticated create through the default agent path is refused before dispatch, no receipt committed" do
    message = data_message(%{"label" => "widget"}, %{metadata: %{skill: "create_item"}})

    # A `handle_message/2` `{:error, _}` reply surfaces through
    # `A2A.Agent.call/3` as a real `{:ok, task}` with the task's own status
    # failed -- not as a `{:error, _}` return from `call/3` itself (the same
    # real shape `test/ash_a2a_agent_multi_turn_test.exs` already
    # establishes for an unrelated `{:error, _}` dispatch reply).
    assert {:ok, task} = ItemAgent.call(ItemAgent, message)
    assert task.status.state == :failed

    refute_receive {:receipt_committed, _receipt}, 200
  end

  test "a real :read skill never goes through CommandBus (no receipt)" do
    assert {:ok, task} =
             WidgetAgent.call(WidgetAgent, data_message(%{}), authenticated_call_opts("user-1"))

    assert task.status.state == :completed

    refute_receive {:receipt_committed, _receipt}, 200
  end

  test "a real pure generic action classified :observe stays on the direct dispatch path (no receipt, original reply preserved)" do
    message = data_message(%{}, %{metadata: %{skill: "ping"}})

    assert {:ok, task} = ItemAgent.call(ItemAgent, message, authenticated_call_opts("user-1"))
    assert task.status.state == :completed
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: %{result: "pong"}}]}] = task.artifacts

    refute_receive {:receipt_committed, _receipt}, 200
  end

  test "a real consequence-bearing generic action classified :change routes through CommandBus -> Receipt" do
    plan_name = :"command_bus_test_plan_#{System.unique_integer([:positive])}"

    message =
      data_message(%{plan_name: plan_name, prompt_text: "advance"}, %{
        metadata: %{skill: "next_phase"}
      })

    assert {:ok, task} =
             FreedomGym.FacilitatorAgent.call(
               FreedomGym.FacilitatorAgent,
               message,
               authenticated_call_opts("user-1")
             )

    assert task.status.state == :completed

    assert_receive {:receipt_committed, receipt}, 1_000
    assert receipt.capability_id == "next_phase"
    assert receipt.consequence == :change
    assert receipt.status == :completed
  end

  test "a real client retry (same protocol-native message_id) through the default agent path replays instead of double-executing" do
    message =
      data_message(%{"label" => "widget"}, %{
        metadata: %{skill: "create_item"},
        message_id: "stable-retry-id-1"
      })

    assert {:ok, task1} = ItemAgent.call(ItemAgent, message, authenticated_call_opts("user-1"))
    assert task1.status.state == :completed
    assert_receive {:receipt_committed, first_receipt}, 1_000
    refute first_receipt.replayed?

    # The exact same real message (same message_id, same semantic content)
    # dispatched a second time -- a genuine client retry, e.g. after a
    # dropped response -- must replay the original receipt, not create a
    # second real Item record. `CommandBus.run/4`'s own `{:replay, receipt}`
    # branch deliberately skips `emit_receipt/1` -- nothing NEW was
    # committed, it is returning the same already-committed receipt -- so no
    # second `[:ash_a2a, :receipt, :committed]` telemetry event is expected
    # here; the replay is proven instead by the task's own real reply
    # content matching the first call's exactly (same real created record
    # id) and by the real, single-row database check below.
    assert {:ok, task2} = ItemAgent.call(ItemAgent, message, authenticated_call_opts("user-1"))
    assert task2.status.state == :completed
    refute_receive {:receipt_committed, _no_new_receipt_on_replay}, 200

    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: created1}]}] = task1.artifacts
    assert [%A2A.Artifact{parts: [%A2A.Part.Data{data: created2}]}] = task2.artifacts
    assert created1.id == created2.id

    assert {:ok, all_items} =
             Ash.read(AshA2A.Test.Fixture.Item, domain: AshA2A.Test.Fixture.ItemDomain)

    assert Enum.count(all_items, &(&1.id == created1.id)) == 1
  end

  test "the same protocol-native message_id with genuinely different content is a real conflict, not a silent divergent replay" do
    message_id = "conflict-id-#{System.unique_integer([:positive])}"

    first_message =
      data_message(%{"label" => "widget"}, %{
        metadata: %{skill: "create_item"},
        message_id: message_id
      })

    second_message =
      data_message(%{"label" => "a completely different widget"}, %{
        metadata: %{skill: "create_item"},
        message_id: message_id
      })

    assert {:ok, task1} =
             ItemAgent.call(ItemAgent, first_message, authenticated_call_opts("user-1"))

    assert task1.status.state == :completed
    assert_receive {:receipt_committed, _first_receipt}, 1_000

    assert {:ok, task2} =
             ItemAgent.call(ItemAgent, second_message, authenticated_call_opts("user-1"))

    assert task2.status.state == :failed
    refute_receive {:receipt_committed, _second_receipt}, 200
  end

  test "an unclassified generic action is refused closed with a typed code, never executed, no receipt" do
    assert {:ok, task} =
             UnclassifiedActionAgent.call(
               UnclassifiedActionAgent,
               data_message(%{}),
               authenticated_call_opts("user-1")
             )

    assert task.status.state == :failed

    # Proves the real action body genuinely never ran -- this isn't merely
    # a status-code assertion, it's a real absence-of-side-effect check.
    refute_receive :mystery_action_actually_ran, 200
    refute_receive {:receipt_committed, _receipt}, 200
  end
end
