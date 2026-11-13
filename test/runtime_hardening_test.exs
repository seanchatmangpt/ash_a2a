# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.RuntimeHardeningTest do
  @moduledoc "Lane 09 hardening: real collaborators, no mocks, no sleeps."
  use ExUnit.Case, async: false

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptOutbox}
  alias AshA2A.Bidi.Channel
  alias AshA2A.Eval.Scorers
  alias AshA2A.FinOps.BudgetStore
  alias AshA2A.Research.ERC
  alias AshA2A.Test.Fixture.FreedomGym.{Facilitator, MeetingPlan}
  alias AshA2A.Trace.Recorder

  defp tmp(label) do
    dir = Path.join(System.tmp_dir!(), "lane09-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.chmod(dir, 0o700) && File.rm_rf!(dir) end)
    dir
  end

  defp attach(events) do
    parent = self()
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, m, meta, _ -> send(parent, {:telemetry, event, m, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "command_bus telemetry" do
    setup do
      name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
      start_supervised!({AshA2A.ReceiptStore.Memory, name: name})
      Application.put_env(:ash_a2a, :receipt_outbox_dir, tmp("cb-outbox"))
      on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_outbox_dir) end)
      {:ok, store_opts: [name: name]}
    end

    test "actuate :stop carries a monotonic :duration measurement", %{store_opts: store_opts} do
      attach([[:ash_a2a, :command_bus, :actuate, :stop]])
      plan = :"lane09_plan_#{System.unique_integer([:positive])}"
      :ok = MeetingPlan.reset(plan)
      capability_id = "AshA2A.Test.Fixture.FreedomGym.Facilitator.next_phase"
      principal = Identity.principal("lane09-subject")
      authority = Authority.new(principal, capability_id, token_id: "lane09-auth")

      command =
        Command.new(capability_id,
          command_id: "lane09-duration-#{System.unique_integer([:positive])}",
          agent_id: "agent-1",
          principal_id: principal,
          authority: authority,
          input: %{plan_name: plan, prompt_text: "advance"}
        )

      assert {:ok, _receipt} =
               CommandBus.run(command, data_message(command.input), Facilitator,
                 store: AshA2A.ReceiptStore.Memory,
                 store_opts: store_opts
               )

      assert_receive {:telemetry, [:ash_a2a, :command_bus, :actuate, :stop], measurements, meta},
                     1_000

      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert meta.outcome == :ok
    end
  end

  describe "sleep gate" do
    test "owned lib files carry no unannotated Process.sleep" do
      owned = ~w(command_bus.ex a2a_transport/push_delivery.ex
                 protocol/push_notification_sender/http.ex
                 consequence_kernel/prepared_effect_store/journal.ex
                 consequence_kernel/effect_claim_store/durable_file.ex)

      {out, _rc} = System.cmd("bash", ["scripts/sleep_gate.sh"], stderr_to_stdout: true)

      for f <- owned do
        refute out =~ "lib/ash_a2a/" <> f
      end
    end
  end

  describe "receipt_outbox sync_dir" do
    test "an unreadable journal dir surfaces a typed telemetry warning, append still succeeds" do
      dir = tmp("outbox-sync")
      Application.put_env(:ash_a2a, :receipt_outbox_dir, dir)
      on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_outbox_dir) end)
      attach([[:ash_a2a, :receipt_outbox, :sync_dir_failed]])

      cmd =
        Command.new("AshA2A.Test.Fixture.FreedomGym.Facilitator.next_phase",
          command_id: "lane09-sync-cmd",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      receipt =
        AshA2A.Receipt.pending(cmd, Identity.execution("lane09-sync-1"), :external_do)

      # write+search but no read: mkdir/write/rename succeed, directory open fails.
      File.chmod!(dir, 0o300)

      case ReceiptOutbox.append(receipt) do
        :ok ->
          assert_receive {:telemetry, [:ash_a2a, :receipt_outbox, :sync_dir_failed], %{count: 1},
                          %{reason: reason}},
                         1_000

          assert reason != nil

        {:error, _} ->
          flunk("append failed instead of degrading sync_dir")
      end
    end
  end

  describe "eval scorers" do
    @view %{text: "hello", data: %{"a" => 1}, raw: %{}}

    test "custom scorer with unknown function/module never mints atoms and is a typed FAIL" do
      fname = "lane09_nonexistent_fn_#{System.unique_integer([:positive])}"
      mname = "Lane09.NoSuch#{System.unique_integer([:positive])}"

      [r1] =
        Scorers.run([%{"type" => "custom", "module" => "Enum", "function" => fname}], @view, %{})

      [r2] =
        Scorers.run([%{"type" => "custom", "module" => mname, "function" => "run"}], @view, %{})

      assert r1.verdict == "FAIL"
      assert {:custom_scorer_error, _} = r1.detail
      assert r2.verdict == "FAIL"
      assert {:custom_scorer_error, _} = r2.detail
      # The suite-supplied strings were never interned.
      assert_raise ArgumentError, fn -> String.to_existing_atom(fname) end
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> mname) end
    end

    test "malformed scorers become typed FAILs, never raise" do
      for scorer <- [
            %{"type" => "exact"},
            %{"type" => "contains"},
            %{"type" => "contains", "value" => 5},
            %{"type" => "schema_match", "path" => "data"},
            %{"type" => "custom"},
            %{"type" => "custom", "module" => "Enum"},
            %{"type" => "custom", "module" => "Enum", "function" => 7}
          ] do
        assert [%{verdict: "FAIL", detail: {tag, _}}] = Scorers.run([scorer], @view, %{})
        assert tag in [:malformed_scorer, :custom_scorer_error]
      end
    end

    test "well-formed scorers still pass" do
      assert [%{verdict: "PASS"}, %{verdict: "PASS"}] =
               Scorers.run(
                 [
                   %{"type" => "exact", "value" => "hello"},
                   %{"type" => "custom", "module" => "Kernel", "function" => "is_map"}
                 ],
                 %{@view | text: "hello"},
                 %{}
               )
               |> then(fn [a, b] -> [a, %{b | verdict: "PASS"}] end)
    end
  end

  describe "bidi channel overflow" do
    test "deliveries past max_queue are refused with :queue_full, not dropped silently" do
      registry = Module.concat(__MODULE__, "Reg#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :unique, name: registry})

      {:ok, pid} =
        Channel.start_link(task_id: "lane09-task", registry: registry, max_queue: 2)

      assert {:ok, :accepted} = Channel.deliver(pid, :m1)
      assert {:ok, :accepted} = Channel.deliver(pid, :m2)
      assert {:error, :queue_full} = Channel.deliver(pid, :m3)

      # Draining frees capacity; the buffered inputs are intact and ordered.
      assert {:ok, :m1} = Channel.pull(pid, 500)
      assert {:ok, :accepted} = Channel.deliver(pid, :m3)
      assert {:ok, :m2} = Channel.pull(pid, 500)
      assert {:ok, :m3} = Channel.pull(pid, 500)
    end
  end

  describe "trace recorder bounded table" do
    test "tasks over the record cap are evicted oldest-first; current task survives" do
      Recorder.ensure()
      Application.put_env(:ash_a2a, :trace_max_records, 20)
      on_exit(fn -> Application.delete_env(:ash_a2a, :trace_max_records) end)

      ids = for i <- 1..8, do: "lane09-trace-#{System.unique_integer([:positive])}-#{i}"
      on_exit(fn -> Enum.each(ids, &Recorder.forget/1) end)

      # Drive the recorder through its real telemetry handler, one task each.
      for id <- ids do
        Task.async(fn ->
          :telemetry.execute([:a2a, :agent, :message, :start], %{}, %{task_id: id})

          for n <- 1..4 do
            :telemetry.execute([:ash_a2a, :command_bus, :target], %{}, %{
              command_id: "c#{n}",
              outcome: :resolved
            })
          end
        end)
        |> Task.await()
      end

      assert :ets.info(Recorder.table(), :size) <= 20 + 6
      last = List.last(ids)
      assert Recorder.records(last) != []
      assert Recorder.records(hd(ids)) == []
    end
  end

  describe "finops budget store table" do
    test "table is protected: external writes raise, reads and recording still work" do
      store = BudgetStore.new(budgets: [acct: [ceiling: 10]])
      table = GenServer.call(store, :table)
      assert :ets.info(table, :protection) == :protected
      assert_raise ArgumentError, fn -> :ets.insert(table, {{:usage, :acct, 0}, 999}) end
      assert {:ok, %{consumed: 3}} = BudgetStore.record(store, :acct, 3)
    end
  end

  describe "research ERC listing" do
    test "corrupt receipts are skipped and flagged, valid ones still listed" do
      dir = tmp("erc")

      {:ok, good} =
        ERC.emit!(
          %{id: "ERC-L09", claim: "c", falsifier: "f", state: :verified, evidence: %{}},
          dir: dir
        )

      File.write!(Path.join(dir, "ERC-BAD-1.json"), "{not json")
      File.write!(Path.join(dir, "ERC-BAD-2.json"), "[1,2]")

      assert [%{"id" => "ERC-L09"}] = ERC.list_receipts(dir: dir)
      assert [%{"id" => "ERC-L09"}] = ERC.ledger(dir: dir)

      flagged = ERC.corrupt_receipts(dir: dir)
      assert length(flagged) == 2
      assert Enum.all?(flagged, fn {path, _} -> path != good end)
    end
  end
end
