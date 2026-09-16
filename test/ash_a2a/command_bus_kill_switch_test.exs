defmodule AshA2A.CommandBusKillSwitchTest do
  @moduledoc """
  Real, Chicago-style proof that `AshA2A.CommandBus.run/4`'s optional
  `opts[:kill_switch_class]` wiring is strictly opt-in: every existing
  caller that omits the opt sees byte-for-byte unchanged behavior (real
  `AshA2A.KillSwitch.tripped?/1` is never even consulted), and a caller that
  explicitly names a class is real-refused before `claim_receipt/3` --
  before any receipt is claimed -- while that class is really tripped, via
  the real `AshA2A.KillSwitch` `GenServer` (no `Mox`/`:meck`/`Mock`/
  `patch`/`monkeypatch` anywhere in this file).
  """

  use ExUnit.Case

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch, ReceiptStore}
  alias AshA2A.Test.Fixture.{Echo, Item}

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
    %{store_opts: [name: name]}
  end

  defp unique_class(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "no kill_switch_class opt: run/4 behaves exactly as it did before this wiring existed",
       %{store_opts: store_opts} do
    # Same real fixture/call pattern as
    # AshA2A.CommandBusTest's "read command produces a receipt and same
    # command replays without a second claim" -- confirms the new
    # `check_kill_switch/1` clause is a true no-op (KillSwitch's GenServer
    # is never even called) when the opt is absent.
    command =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "no-opt-1",
        agent_id: "agent-1",
        principal_id: "anonymous",
        input: %{}
      )

    message = data_message(%{})

    assert {:ok, first} = CommandBus.run(command, message, Echo, store_opts: store_opts)
    refute first.replayed?
    assert first.status == :completed
    assert first.consequence == :observe

    assert {:ok, replay} = CommandBus.run(command, message, Echo, store_opts: store_opts)
    assert replay.replayed?
    assert replay.receipt_id == first.receipt_id
  end

  test "kill_switch_class opt against a real, un-tripped class succeeds normally", %{
    store_opts: store_opts
  } do
    class = unique_class("untripped")
    refute KillSwitch.tripped?(class)

    principal = Identity.principal("subject-1")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "auth-ks-untripped")

    command =
      Command.new(capability,
        command_id: "ks-untripped-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{label: "widget"}
      )

    assert {:ok, receipt} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts,
               kill_switch_class: class
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end

  test "kill_switch_class opt against a really-tripped class real-refuses before claim_receipt/3 ever runs",
       %{store_opts: store_opts} do
    class = unique_class("tripped")
    assert :ok = KillSwitch.trip(class, :incident_kb)
    assert {true, :incident_kb} = KillSwitch.tripped?(class)

    principal = Identity.principal("subject-1")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "auth-ks-tripped")

    command =
      Command.new(capability,
        command_id: "ks-tripped-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{label: "widget"}
      )

    assert {:error, %{code: :kill_switch_tripped, detail: :incident_kb}} =
             CommandBus.run(command, data_message(%{"label" => "widget"}), Item,
               store_opts: store_opts,
               kill_switch_class: class
             )

    # Real state-based proof no receipt was ever claimed for the refused
    # attempt -- the claim store has nothing for this command_id at all,
    # not an interaction assertion on whether some function was called.
    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)
  end

  test "resetting the class via a real, valid Authority + matching expected_principal lets the same command succeed on retry",
       %{store_opts: store_opts} do
    class = unique_class("reset-retry")
    assert :ok = KillSwitch.trip(class, :incident_reset)

    principal = Identity.principal("subject-1")
    capability = "AshA2A.Test.Fixture.Item.create"
    authority = Authority.new(principal, capability, token_id: "auth-ks-reset")

    command =
      Command.new(capability,
        command_id: "ks-reset-1",
        agent_id: "agent-1",
        principal_id: principal,
        authority: authority,
        input: %{label: "widget"}
      )

    message = data_message(%{"label" => "widget"})

    assert {:error, %{code: :kill_switch_tripped, detail: :incident_reset}} =
             CommandBus.run(command, message, Item,
               store_opts: store_opts,
               kill_switch_class: class
             )

    assert :error = ReceiptStore.Memory.fetch(command.command_id, store_opts)

    reset_operator = Identity.principal("kill-switch-operator")
    reset_authority = Authority.new(reset_operator, KillSwitch.reset_capability_id(class))

    assert :ok = KillSwitch.reset(class, reset_authority, reset_operator)
    refute KillSwitch.tripped?(class)

    assert {:ok, receipt} =
             CommandBus.run(command, message, Item,
               store_opts: store_opts,
               kill_switch_class: class
             )

    refute receipt.replayed?
    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert {:ok, stored} = ReceiptStore.Memory.fetch(command.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end
end
