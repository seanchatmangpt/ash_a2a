# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.FinOpsCourtTest do
  @moduledoc """
  FR-05 FinOps court (PRD §6.5): quota breach halts dispatch prior to
  action execution, recording a typed refusal receipt.

  Real collaborators throughout (Chicago discipline): a real supervised
  `AshA2A.FinOps.BudgetStore` owning a real ETS table, real concurrent OS
  processes contending for the same budget account, real `:telemetry`
  events, and a real downstream side-effect ledger (a real Agent
  process) that only advances when the gate admits. No `Mox`/`:meck`/
  stub appears anywhere.
  """

  use ExUnit.Case, async: false

  alias AshA2A.FinOps.BudgetEnforcer
  alias AshA2A.FinOps.BudgetStore
  alias AshA2A.FinOps.Chargeback
  alias AshA2A.Semantic.Refusal

  # A real downstream side-effect ledger: a real Agent process holding
  # real state, advanced only when the gate admits. This is the FR-05.3
  # witness -- a breach must leave it untouched.
  defmodule Ledger do
    def start(name), do: Agent.start_link(fn -> [] end, name: name)
    def run(ledger, tag, tokens), do: Agent.update(ledger, &[{tag.budget_account_id, tokens} | &1])
    def entries(ledger), do: Agent.get(ledger, &Enum.reverse/1)
  end

  defp start_store(opts \\ []) do
    start_supervised!(
      {BudgetStore, Keyword.merge([name: Module.concat(__MODULE__, "Store", Integer.to_string(System.unique_integer()))], opts)}
    )
  end

  defp start_ledger do
    name = Module.concat(__MODULE__, "Ledger", Integer.to_string(System.unique_integer()))
    {:ok, _} = Ledger.start(name)
    name
  end

  # A real dispatch pipeline: the gate runs first; the ledger advances
  # only on admission.
  defp dispatch(store, ledger, request, opts \\ []) do
    case BudgetEnforcer.authorize(store, request, opts) do
      {:ok, tag} ->
        Ledger.run(ledger, tag, tag.requested)
        {:ok, tag}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  describe "FR-05.1 cost attribution resolution" do
    test "resolves cost_center and budget_account_id from request metadata (atom keys)" do
      store = start_store(budgets: [{"acct-invoice", ceiling: 1_000}])

      assert {:ok, %Chargeback{} = tag} =
               dispatch(store, start_ledger(), %{
                 cost_center: "cc-invoice",
                 budget_account_id: "acct-invoice"
               })

      assert tag.cost_center == "cc-invoice"
      assert tag.budget_account_id == "acct-invoice"
      assert tag.ceiling == 1_000
    end

    test "resolves from string keys and header forms" do
      store = start_store(budgets: [{"acct-2", ceiling: 100}])
      ledger = start_ledger()

      assert {:ok, tag} =
               dispatch(store, ledger, %{
                 "cost_center" => "cc-strings",
                 "budget_account_id" => "acct-2",
                 "estimated_tokens" => 1
               })

      assert tag.cost_center == "cc-strings"

      assert {:ok, tag2} =
               dispatch(store, ledger, %{
                 "x-cost-center" => "cc-headers",
                 "x-budget-account-id" => "acct-2"
               })

      assert tag2.cost_center == "cc-headers"
    end

    test "falls back to configured defaults" do
      store = start_store(budgets: [{"acct-default", ceiling: 100}])
      ledger = start_ledger()

      Application.put_env(:ash_a2a, :finops,
        default_cost_center: "cc-default",
        default_budget_account_id: "acct-default"
      )

      on_exit(fn -> Application.delete_env(:ash_a2a, :finops) end)

      assert {:ok, tag} = dispatch(store, ledger, %{"estimated_tokens" => 1})
      assert tag.cost_center == "cc-default"
      assert tag.budget_account_id == "acct-default"
    after
      Application.delete_env(:ash_a2a, :finops)
    end

    test "unresolvable attribution is a typed refusal, not a silent default" do
      store = start_store(budgets: [])
      ledger = start_ledger()

      assert {:error, %{code: :invalid_request} = refusal} = dispatch(store, ledger, %{"tokens" => 1})
      assert %{missing: :cost_center, reason: reason} = refusal.detail
      assert is_binary(reason)

      lifted = Refusal.from_error(refusal, :finops)
      assert lifted.class == :refused_structure
      assert lifted.lawful? == true
      assert lifted.code == :invalid_request
    end
  end

  describe "FR-05.2/05.3 hard ceiling enforcement" do
    test "under-quota dispatch passes and records consumption" do
      store = start_store(budgets: [{"acct-a", ceiling: 1_000}])
      ledger = start_ledger()

      assert {:ok, tag} =
               dispatch(store, ledger, %{
                 cost_center: "cc-a",
                 budget_account_id: "acct-a",
                 estimated_tokens: 400
               })

      assert tag.consumed == 400
      assert tag.requested == 400
      assert BudgetStore.usage(store, "acct-a") == 400
      assert BudgetStore.total(store, "acct-a") == 400
      assert Ledger.entries(ledger) == [{"acct-a", 400}]
    end

    test "quota breach halts dispatch BEFORE execution with a typed refusal (zero downstream side effects)" do
      store = start_store(budgets: [{"acct-b", ceiling: 500}])
      ledger = start_ledger()

      # Exactly 100% of quota is admissible.
      assert {:ok, tag} =
               dispatch(store, ledger, %{cost_center: "cc-b", budget_account_id: "acct-b", tokens: 500})

      assert tag.consumed == 500

      # One more token over the hard ceiling: refused, dispatch never runs.
      assert {:error, %{code: :budget_exceeded} = refusal} =
               dispatch(store, ledger, %{cost_center: "cc-b", budget_account_id: "acct-b", tokens: 1})

      assert refusal.detail.ceiling == 500
      assert refusal.detail.requested == 1

      lifted = Refusal.from_error(refusal, :finops)
      assert lifted.class == :refused_bounds
      assert lifted.lawful? == true
      assert lifted.code == :budget_exceeded

      # FR-05.3: zero downstream execution side effects -- the real ledger
      # holds exactly the one admitted dispatch, nothing from the breach.
      assert Ledger.entries(ledger) == [{"acct-b", 500}]

      # A refusal never inflates chargeback consumption.
      assert BudgetStore.usage(store, "acct-b") == 500
    end

    test "an account with no configured ceiling is refused fail-closed" do
      start_store(budgets: [])
      ledger = start_ledger()

      assert {:error, %{code: :missing_evidence} = refusal} =
               BudgetEnforcer.authorize(store, %{cost_center: "cc-x", budget_account_id: "unknown-acct"})

      lifted = Refusal.from_error(refusal, :finops)
      assert lifted.class == :refused_provenance
      assert Ledger.entries(ledger) == []
    end
  end

  describe "concurrency over the real ETS store" do
    test "concurrent reservations are counted exactly and never exceed the ceiling" do
      store = start_store(budgets: [{"acct-conc", ceiling: 200}])
      ledger = start_ledger()

      results =
        1..50
        |> Enum.map(fn _ ->
          Task.async(fn ->
            BudgetEnforcer.authorize(store, %{
              cost_center: "cc-conc",
              budget_account_id: "acct-conc",
              tokens: 4
            })
          end)
        end)
        |> Task.await_many(30_000)

      assert {admitted, refused} = Enum.split_with(results, &match?({:ok, _}, &1))
      assert length(admitted) == 50
      assert refused == []

      # Exactly 50 * 4 = 200 recorded: real concurrent processes, real
      # serialized check-and-reserve, no lost increments, no overage.
      assert BudgetStore.usage(store, "acct-conc") == 200
      assert length(Ledger.entries(ledger)) == 50
    end

    test "concurrent oversubscription admits exactly the ceiling, refuses the rest" do
      store = start_store(budgets: [{"acct-race", ceiling: 5}])
      ledger = start_ledger()

      results =
        1..25
        |> Enum.map(fn _ ->
          Task.async(fn ->
            BudgetEnforcer.authorize(store, %{
              cost_center: "cc-race",
              budget_account_id: "acct-race",
              tokens: 1
            })
          end)
        end)
        |> Task.await_many(30_000)

      admitted = Enum.count(results, &match?({:ok, _}, &1))
      refused = Enum.count(results, &match?({:error, %{code: :budget_exceeded}}, &1))

      assert admitted == 5
      assert refused == 20
      assert BudgetStore.usage(store, "acct-race") == 5
      assert length(Ledger.entries(ledger)) == 5
    end
  end

  describe "chargeback telemetry tagging" do
    defmodule Collector do
      def collect(events, event, measurements, metadata),
        do: Agent.update(events, &[{event, measurements, metadata} | &1])

      def events(agent), do: Agent.get(agent, &Enum.reverse/1)
    end

    test "admissions and refusals both carry billing metadata" do
      store = start_store(budgets: [{"acct-tel", ceiling: 10}])
      {:ok, collector} = Agent.start_link(fn -> [] end)

      handler_id = {__MODULE__, :chargeback_collector, make_ref()}

      :telemetry.attach(
        handler_id,
        BudgetEnforcer.chargeback_event(),
        &Collector.collect/4,
        collector
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _} =
               BudgetEnforcer.authorize(store, %{
                 cost_center: "cc-tel",
                 budget_account_id: "acct-tel",
                 tokens: 6
               })

      assert {:error, _} =
               BudgetEnforcer.authorize(store, %{
                 cost_center: "cc-tel",
                 budget_account_id: "acct-tel",
                 tokens: 9
               })

      events = Collector.events(collector)
      assert length(events) == 2

      [admit, refuse] = events
      assert {[:ash_a2a, :finops, :chargeback], _, _} = admit

      {_, admit_measurements, admit_meta} = admit
      assert admit_measurements.tokens == 6
      assert admit_meta.cost_center == "cc-tel"
      assert admit_meta.budget_account_id == "acct-tel"
      assert admit_meta.ceiling == 10
      assert admit_meta.admitted == true
      assert admit_meta.consumed == 6
      assert admit_meta.code == nil

      {_, refuse_measurements, refuse_meta} = refuse
      assert refuse_measurements.tokens == 9
      assert refuse_meta.admitted == false
      assert refuse_meta.code == :budget_exceeded
      assert refuse_meta.cost_center == "cc-tel"
      assert refuse_meta.budget_account_id == "acct-tel"
      assert refuse_meta.ceiling == 10
    end
  end

  describe "billing windows" do
    test "usage resets at the window boundary; lifetime total is preserved" do
      store = start_store(budgets: [{"acct-win", ceiling: 1_000, window_ms: 50}])

      assert {:ok, %{window_started_at: started, window_ms: 50}} =
               BudgetStore.record(store, "acct-win", 100)

      assert BudgetStore.usage(store, "acct-win") == 100
      assert BudgetStore.total(store, "acct-win") == 100
      assert is_integer(started)

      Process.sleep(80)

      assert BudgetStore.usage(store, "acct-win") == 0
      assert BudgetStore.total(store, "acct-win") == 100

      # The new window has the full ceiling available again.
      assert {:ok, %{consumed: 500, window_started_at: started2}} =
               BudgetStore.record(store, "acct-win", 500)

      assert started2 > started
      assert BudgetStore.total(store, "acct-win") == 600
    end

    test "settle/3 charges only the delta above the reservation" do
      store = start_store(budgets: [{"acct-settle", ceiling: 1_000}])

      assert {:ok, tag} =
               BudgetEnforcer.authorize(store, %{
                 cost_center: "cc-settle",
                 budget_account_id: "acct-settle",
                 tokens: 100
               })

      assert :ok = BudgetEnforcer.settle(store, tag, 80)
      assert BudgetStore.usage(store, "acct-settle") == 100

      assert {:ok, %{consumed: 260}} = BudgetEnforcer.settle(store, tag, 260)
      assert BudgetStore.usage(store, "acct-settle") == 260
    end

    test "set_budget validates its arguments (programmer error, not refusal)" do
      store = start_store(budgets: [])

      assert_raise ArgumentError, fn -> BudgetStore.set_budget(store, "a", 0) end
      assert_raise ArgumentError, fn -> BudgetStore.set_budget(store, "a", -5) end
      assert_raise ArgumentError, fn -> BudgetStore.set_budget(store, "a", 10, window_ms: 0) end

      assert :ok = BudgetStore.set_budget(store, "acct-late", 42)
      assert {:ok, 42} = BudgetStore.ceiling(store, "acct-late")
    end
  end
end
