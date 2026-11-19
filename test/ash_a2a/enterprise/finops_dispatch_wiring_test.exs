# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.FinOpsDispatchWiringCourtTest do
  @moduledoc """
  Lane V4-18 court: the FR-05 FinOps gate is actually INVOKED pre-dispatch in
  `AshA2A.Dispatcher` (closes V4-9's typed gap).

  Real collaborators throughout (Chicago discipline): a real supervised
  `AshA2A.FinOps.BudgetStore` owning a real ETS table, a real ETS-backed Ash
  resource (`AshA2A.Test.Fixture.Item`) whose persisted record count is the
  execution side-effect witness, the real `AshA2A.CommandBus` -> anchor ->
  dispatcher path (`AshA2A.Test.ReceiptedDispatch`) so the consequence-bearing
  `:create_item` skill is dispatched the one lawful way, real `:telemetry`
  chargeback events, and the real `Application` env as the config gate. No
  mock/stub/patch anywhere in this file.
  """

  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.FinOps.BudgetStore
  alias AshA2A.Test.Fixture.Item
  alias AshA2A.Test.Fixture.ItemDomain
  alias AshA2A.Test.ReceiptedDispatch

  defp start_store(opts) do
    name = String.to_atom("finops_wiring_store_#{System.unique_integer()}")
    start_supervised!({BudgetStore, Keyword.merge([name: name], opts)})
  end

  defp configure_finops(conf) do
    Application.put_env(:ash_a2a, :finops, conf)
    on_exit(fn -> Application.delete_env(:ash_a2a, :finops) end)
  end

  # NB: `AshA2A.CommandBus` dedupes identical command fingerprints (capability
  # + input) and replays the prior receipt's reply WITHOUT re-dispatching, so
  # each dispatch in a court must carry a distinct `label` input to reach
  # `AshA2A.Dispatcher.do_dispatch/6` at all.
  defp wire_message(metadata_overrides, label) do
    metadata =
      Map.merge(
        %{
          "x-cost-center" => "cc-wire",
          "x-budget-account-id" => "acct-wire",
          "estimated_tokens" => 100
        },
        Map.new(metadata_overrides)
      )

    data_message(%{"label" => label}, %{metadata: metadata})
  end

  # The `AshA2A.Test.Fixture.Item` ETS table persists across the whole VM
  # (other files' courts create Items too), so witnesses count only THIS
  # court's uniquely-labeled records.
  defp count_by_label(label) do
    {:ok, items} = Ash.read(Item, domain: ItemDomain)

    items
    |> Enum.count(&(&1.label == label))
  end

  describe "FR-05 gate invocation in the dispatch pipeline" do
    test "quota breach refuses the second dispatch BEFORE any execution side effect" do
      store = start_store(budgets: [{"acct-wire", ceiling: 100}])
      configure_finops(budget_store: store)

      # First dispatch: exactly 100% of quota -- admitted, real side effect.
      assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{label: "v418-quota-1", id: id1}}]} =
               ReceiptedDispatch.dispatch(:create_item, wire_message(%{}, "v418-quota-1"), Item)

      refute is_nil(id1)
      assert count_by_label("v418-quota-1") == 1

      # Second dispatch: a DIFFERENT command (distinct label, so the
      # CommandBus fingerprint dedupe can't replay a prior receipt) that
      # would push past the exhausted hard ceiling. Refused typed
      # (`:budget_exceeded`, S42 `:refused_bounds`), tagged with the gate
      # stage, BEFORE the Ash action runs.
      assert {:error, {:finops_gate, %{code: :budget_exceeded, detail: detail}}} =
               ReceiptedDispatch.dispatch(:create_item, wire_message(%{}, "v418-quota-2"), Item)

      assert detail.ceiling == 100
      assert detail.requested == 100
      assert detail.consumed == 100

      # Execution side-effect witness: the real ETS-backed resource holds
      # exactly the ONE admitted create -- the refused request executed
      # nothing downstream.
      assert count_by_label("v418-quota-2") == 0

      # A refusal never inflates chargeback consumption.
      assert BudgetStore.usage(store, "acct-wire") == 100
    end

    test "finops unconfigured: dispatch proceeds exactly as before (regression guard)" do
      # The wiring default: no `config :ash_a2a, :finops` at all.
      assert Application.get_env(:ash_a2a, :finops) == nil

      assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{label: "v418-regression", id: id}}]} =
               ReceiptedDispatch.dispatch(
                 :create_item,
                 wire_message(%{"estimated_tokens" => 0}, "v418-regression"),
                 Item
               )

      refute is_nil(id)
      assert count_by_label("v418-regression") == 1
    end
  end

  describe "FR-05.1 attribution over the real dispatcher" do
    test "resolves x-cost-center / x-budget-account-id headers end to end" do
      store = start_store(budgets: [{"acct-hdr", ceiling: 1_000}])
      configure_finops(budget_store: store)

      {:ok, collector} = Agent.start_link(fn -> [] end)

      handler_id = {__MODULE__, :wiring_chargeback_collector, make_ref()}

      :telemetry.attach(
        handler_id,
        [:ash_a2a, :finops, :chargeback],
        fn event, measurements, metadata, agent ->
          Agent.update(agent, &[{event, measurements, metadata} | &1])
        end,
        collector
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:reply, [%AshA2A.Protocol.Part.Data{data: %{label: "v418-headers", id: _id}}]} =
               ReceiptedDispatch.dispatch(
                 :create_item,
                 wire_message(
                   %{
                     "x-cost-center" => "cc-headers",
                     "x-budget-account-id" => "acct-hdr"
                   },
                   "v418-headers"
                 ),
                 Item
               )

      events = Agent.get(collector, &Enum.reverse/1)
      assert length(events) == 1

      [{event, measurements, metadata}] = events
      assert event == [:ash_a2a, :finops, :chargeback]
      assert measurements.tokens == 100
      assert metadata.cost_center == "cc-headers"
      assert metadata.budget_account_id == "acct-hdr"
      assert metadata.ceiling == 1_000
      assert metadata.admitted == true

      # The reservation landed on the header-resolved real account.
      assert BudgetStore.usage(store, "acct-hdr") == 100
    end
  end
end
