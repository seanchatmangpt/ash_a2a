# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.KillSwitchDurabilityTest do
  @moduledoc """
  Finding R6: kill-switch trips survive a process restart (published to
  `:persistent_term`) and, with a configured path, a node restart (DETS);
  and `AshA2A.CommandBus` refuses -- instead of crashing its caller -- when
  the kill switch cannot be consulted.

  Real `AshA2A.KillSwitch` instances under the test supervisor, real
  process kills, a real DETS file in a per-test tmp dir, and a real
  `AshA2A.CommandBus.run/4`. No mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch, ReceiptStore}

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp await_restart(name, old_pid) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != old_pid -> {:halt, pid}
        _ -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  test "a trip survives the kill switch process being killed and restarted" do
    name = unique("ks_restart")
    start_supervised!({KillSwitch, name: name})
    old = Process.whereis(name)

    assert :ok = KillSwitch.trip("payments", :incident_r6, name: name)
    assert {true, :incident_r6} = KillSwitch.tripped?("payments", name)

    Process.exit(old, :kill)
    new = await_restart(name, old)
    assert is_pid(new)

    # Both the lock-free read and the restarted process's own state agree.
    assert {true, :incident_r6} = KillSwitch.tripped?("payments", name)
    assert {true, :incident_r6} = GenServer.call(name, {:tripped?, "payments"})
  end

  test "with a configured path a trip survives a simulated node restart", %{tmp_dir: tmp_dir} do
    name = unique("ks_dets")
    path = Path.join(tmp_dir, "kill_switch.dets")

    start_supervised!({KillSwitch, name: name, path: path})
    assert :ok = KillSwitch.trip("ledger", :node_restart_incident, name: name)
    stop_supervised!(KillSwitch)

    # A node restart loses every in-VM trace; only the DETS file remains.
    :persistent_term.erase({KillSwitch, :trips, name})
    assert catch_exit(KillSwitch.tripped?("ledger", name))

    start_supervised!({KillSwitch, name: name, path: path})
    assert {true, :node_restart_incident} = KillSwitch.tripped?("ledger", name)

    principal = Identity.principal("ks-operator")
    authority = Authority.new(principal, KillSwitch.reset_capability_id("ledger"))
    assert :ok = KillSwitch.reset("ledger", authority, principal, name: name)
    stop_supervised!(KillSwitch)
    :persistent_term.erase({KillSwitch, :trips, name})

    start_supervised!({KillSwitch, name: name, path: path})
    refute KillSwitch.tripped?("ledger", name)
  end

  test "CommandBus refuses with :kill_switch_unavailable and the caller survives when the switch cannot be consulted" do
    store = unique("ks_bus_store")
    start_supervised!({ReceiptStore.Memory, name: store})

    principal = Identity.principal("subject-ks")
    capability = "AshA2A.Test.Fixture.Item.create"

    command =
      Command.new(capability,
        command_id: "ks-unavailable-#{System.unique_integer([:positive])}",
        agent_id: "agent-1",
        principal_id: principal,
        authority: Authority.new(principal, capability, token_id: "auth-ks-unavailable"),
        input: %{label: "widget"}
      )

    assert {:error, %{code: :kill_switch_unavailable}} =
             CommandBus.run(
               command,
               data_message(%{"label" => "widget"}),
               AshA2A.Test.Fixture.Item,
               store_opts: [name: store],
               kill_switch_class: "items",
               kill_switch: unique("ks_never_started")
             )

    # Refused before claim: nothing was claimed for this command id.
    assert :error = ReceiptStore.Memory.fetch(command.command_id, name: store)
  end
end
