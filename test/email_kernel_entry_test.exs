# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Email.KernelEntryTest do
  @moduledoc """
  Real CommandBus path, real InMemory broker, real Item fixture. No doubles.
  Stale-digest handling lives in the plug, not the kernel entry (not applicable here).
  """
  use ExUnit.Case, async: false

  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.Email.KernelEntry
  alias AshA2A.Identity
  alias AshA2A.Test.Fixture.Item

  @capability "AshA2A.Test.Fixture.Item.create"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])

    suffix = System.unique_integer([:positive])
    store = Module.concat(__MODULE__, "Store#{suffix}")
    broker = Module.concat(__MODULE__, "Broker#{suffix}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})
    start_supervised!(Supervisor.child_spec({InMemory, name: broker}, id: broker))

    prior_policy = Application.get_env(:ash_a2a, :authority_policy)
    prior_broker = Application.get_env(:ash_a2a, :authority_broker)
    Application.put_env(:ash_a2a, :authority_policy, :broker)
    Application.put_env(:ash_a2a, :authority_broker, {InMemory, name: broker})

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)
      restore(:authority_policy, prior_policy)
      restore(:authority_broker, prior_broker)
    end)

    %{bus_opts: [store_opts: [name: store]]}
  end

  defp restore(key, nil), do: Application.delete_env(:ash_a2a, key)
  defp restore(key, value), do: Application.put_env(:ash_a2a, key, value)

  defp principal(id),
    do: %{id: id, address: "#{id}@example.com", authenticated_via: :email, authority: :none}

  test "granted principal dispatches through the CommandBus", %{bus_opts: bus_opts} do
    {:ok, _} = Grant.grant(Identity.principal("mail-granted"), @capability)

    assert {:ok, receipt} =
             KernelEntry.run(@capability, %{"label" => "widget"}, Item, principal("mail-granted"),
               bus_opts: bus_opts
             )

    assert receipt.status == :completed
    assert receipt.consequence == :change
  end

  test "principal without a grant is refused with a typed code, nothing dispatched", %{
    bus_opts: bus_opts
  } do
    assert {:error, %{code: :email_no_live_grant}} =
             KernelEntry.run(@capability, %{"label" => "widget"}, Item, principal("mail-nogrant"),
               bus_opts: bus_opts
             )

    assert :email_no_live_grant in Map.keys(AshA2A.Semantic.Refusal.mapping())
  end

  test "revoked grant is refused", %{bus_opts: bus_opts} do
    subject = Identity.principal("mail-revoked")
    {:ok, _} = Grant.grant(subject, @capability)
    :ok = Grant.revoke(subject, @capability)

    assert {:error, %{code: :email_no_live_grant}} =
             KernelEntry.run(@capability, %{"label" => "x"}, Item, principal("mail-revoked"),
               bus_opts: bus_opts
             )
  end

  test "unknown skill is refused capability_not_found", %{bus_opts: bus_opts} do
    assert {:error, %{code: :capability_not_found}} =
             KernelEntry.run("nope", %{}, Item, principal("mail-granted"), bus_opts: bus_opts)
  end
end
