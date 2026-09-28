defmodule AshA2A.Test.Fixture.BusSlowActuator do
  @moduledoc """
  Real `:external_do` resource whose action sleeps `sleep_ms` and then
  performs a real observable effect (a `KeyedActuationCounter` bump) -- the
  subject for the R9 dispatch-deadline tests.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.BusSlowActuatorDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    action :actuate, :integer do
      argument(:effect_key, :string, allow_nil?: false)
      argument(:sleep_ms, :integer, allow_nil?: false)
      argument(:die, :boolean, allow_nil?: false, default: false)

      run(fn input, _context ->
        # `die: true` kills the process running DO with an untrappable
        # signal before the effect -- a DO that vanishes without replying.
        if input.arguments.die, do: Process.exit(self(), :kill)
        Process.sleep(input.arguments.sleep_ms)
        {:ok, AshA2A.Test.Fixture.KeyedActuationCounter.bump(input.arguments.effect_key)}
      end)
    end
  end

  a2a do
    skill(:actuate, :actuate, consequence: :external_do)
  end
end

defmodule AshA2A.Test.Fixture.BusSlowActuatorDomain do
  @moduledoc "Real fixture domain for `AshA2A.Test.Fixture.BusSlowActuator`."

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.Fixture.BusSlowActuator)
  end
end

defmodule AshA2A.Test.Fixture.SupersededClaimStore do
  @moduledoc """
  Real `AshA2A.ReceiptStore` over a real `AshA2A.ReceiptStore.Memory` that
  reproduces the R4 interleaving deterministically: right after this
  executor's claim, a second executor reclaims the same command (lease 0, no
  anchor yet), so the execution id handed back is already superseded. Every
  other callback is the real Memory store.
  """
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  @impl true
  def claim(command, opts) do
    case Memory.claim(command, opts) do
      {:execute, stale} ->
        {:execute, _current} = Memory.claim(command, opts ++ [claim_lease_ms: 0])
        {:execute, stale}

      other ->
        other
    end
  end

  @impl true
  def commit(receipt, opts), do: Memory.commit(receipt, opts)
  @impl true
  def fetch(command_id, opts), do: Memory.fetch(command_id, opts)
  @impl true
  def confirm_claim(command_id, execution_id, opts),
    do: Memory.confirm_claim(command_id, execution_id, opts)

  @impl true
  def claim_actuation(actuation, command, opts),
    do: Memory.claim_actuation(actuation, command, opts)

  @impl true
  def commit_actuation(actuation, receipt, opts),
    do: Memory.commit_actuation(actuation, receipt, opts)

  @impl true
  def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)
end

defmodule AshA2A.Test.Fixture.LostActuationIndexStore do
  @moduledoc """
  Real `AshA2A.ReceiptStore` over a real `AshA2A.ReceiptStore.Memory` whose
  actuation index is down for writes: `commit_actuation/3` answers
  `{:error, :actuation_store_unavailable}` (the R1 shape -- the effect
  completes and the primary receipt commits, the actuation commit is lost).
  """
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  @impl true
  def claim(command, opts), do: Memory.claim(command, opts)
  @impl true
  def commit(receipt, opts), do: Memory.commit(receipt, opts)
  @impl true
  def fetch(command_id, opts), do: Memory.fetch(command_id, opts)
  @impl true
  def confirm_claim(command_id, execution_id, opts),
    do: Memory.confirm_claim(command_id, execution_id, opts)

  @impl true
  def claim_actuation(actuation, command, opts),
    do: Memory.claim_actuation(actuation, command, opts)

  @impl true
  def commit_actuation(_actuation, _receipt, _opts), do: {:error, :actuation_store_unavailable}
  @impl true
  def release_actuation(actuation, opts), do: Memory.release_actuation(actuation, opts)
end

defmodule AshA2A.CommandBusHardeningTest do
  @moduledoc """
  Findings R9 (dispatch deadline) and OBS-04 (OCEL pending-dispatch stash
  hygiene) through the real `AshA2A.CommandBus.run/4`, a real
  `AshA2A.ReceiptStore.Memory`, a real filesystem `AshA2A.ReceiptOutbox`, and
  a real counting side effect. No mocks: "DO did not complete" is the real
  counter value, "the anchor was kept" is the real journal file.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.Test.Fixture.{BusSlowActuator, Echo, KeyedActuationCounter}

  @capability "AshA2A.Test.Fixture.BusSlowActuator.actuate"

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)

      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    start_supervised!(KeyedActuationCounter)
    store = :"bus_hardening_store_#{System.unique_integer([:positive])}"
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store})

    %{store_opts: [name: store]}
  end

  defp slow_command(key, sleep_ms, die \\ false) do
    principal = Identity.principal("bus-hardening-principal")

    Command.new(@capability,
      command_id: "bus-hardening-#{System.unique_integer([:positive])}",
      agent_id: "bus-hardening-agent",
      principal_id: principal,
      authority: Authority.new(principal, @capability, token_id: "bus-hardening-auth"),
      input: %{effect_key: key, sleep_ms: sleep_ms, die: die}
    )
  end

  defp run(command, store_opts, extra) do
    CommandBus.run(
      command,
      data_message(%{
        "effect_key" => command.input.effect_key,
        "sleep_ms" => command.input.sleep_ms,
        "die" => command.input.die
      }),
      BusSlowActuator,
      [store_opts: store_opts] ++ extra
    )
  end

  describe "R9 dispatch deadline" do
    test "a hung DO is killed at the deadline: unknown outcome, anchor kept, retry never re-executes",
         %{store_opts: store_opts} do
      key = "r9-#{System.unique_integer([:positive])}"
      command = slow_command(key, 1_000)

      started = System.monotonic_time(:millisecond)

      assert {:error, %{code: :dispatch_timeout, receipt: %Receipt{} = receipt} = error} =
               run(command, store_opts, dispatch_timeout_ms: 100)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 900, "run/4 returned after #{elapsed}ms; the deadline did not bound DO"

      assert error.outcome_known? == false
      assert receipt.terminal_status == :unknown_outcome
      # The pending anchor is replay-blocking evidence: DO may have run.
      assert ReceiptOutbox.anchored?(receipt)

      # The killed DO never completed its effect, even after its sleep.
      Process.sleep(1_100)
      assert KeyedActuationCounter.count(key) == 0

      # A retry of the same command replays the unknown outcome; no second DO.
      assert {:ok, %Receipt{replayed?: true} = replay} =
               run(command, store_opts, dispatch_timeout_ms: 100)

      assert replay.receipt_id == receipt.receipt_id
      assert replay.terminal_status == :unknown_outcome
      assert KeyedActuationCounter.count(key) == 0
    end

    test "within the deadline DO runs in the bounded child and completes normally",
         %{store_opts: store_opts} do
      key = "r9-ok-#{System.unique_integer([:positive])}"

      assert {:ok, %Receipt{status: :completed} = receipt} =
               run(slow_command(key, 10), store_opts, dispatch_timeout_ms: 5_000)

      assert KeyedActuationCounter.count(key) == 1
      refute ReceiptOutbox.anchored?(receipt)
    end

    test "a trapping caller survives a DO that dies without replying: :dispatch_lost, unknown outcome, no stray EXIT",
         %{store_opts: store_opts} do
      key = "r9-lost-#{System.unique_integer([:positive])}"
      previous = Process.flag(:trap_exit, true)

      try do
        assert {:error, %{code: :dispatch_lost, receipt: %Receipt{} = receipt}} =
                 run(slow_command(key, 0, true), store_opts, dispatch_timeout_ms: 5_000)

        assert receipt.terminal_status == :unknown_outcome
        assert ReceiptOutbox.anchored?(receipt)
        assert KeyedActuationCounter.count(key) == 0
        refute_received {:EXIT, _pid, _reason}
      after
        Process.flag(:trap_exit, previous)
      end
    end

    test "a non-trapping caller dies with a DO killed by a signal (pre-R9 crash semantics)",
         %{store_opts: store_opts} do
      key = "r9-linked-#{System.unique_integer([:positive])}"
      command = slow_command(key, 0, true)

      {pid, monitor} =
        spawn_monitor(fn -> run(command, store_opts, dispatch_timeout_ms: 5_000) end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      assert KeyedActuationCounter.count(key) == 0
      assert [%Receipt{status: :pending}] = ReceiptOutbox.entries()
    end

    test ":infinity keeps the pre-R9 in-process dispatch", %{store_opts: store_opts} do
      key = "r9-inf-#{System.unique_integer([:positive])}"

      assert {:ok, %Receipt{status: :completed}} =
               run(slow_command(key, 10), store_opts, dispatch_timeout_ms: :infinity)

      assert KeyedActuationCounter.count(key) == 1
    end
  end

  describe "R4 execution fencing at the bus" do
    test "a superseded execution is refused before DO: no effect, anchor removed",
         %{store_opts: store_opts} do
      key = "r4-bus-#{System.unique_integer([:positive])}"

      assert {:error, %{code: :stale_execution}} =
               run(slow_command(key, 0), store_opts,
                 store: AshA2A.Test.Fixture.SupersededClaimStore
               )

      assert KeyedActuationCounter.count(key) == 0
      assert ReceiptOutbox.count() == 0
    end
  end

  describe "R1 lost actuation commit at the bus" do
    test "the failure is observable and a second command for the same effect never re-runs DO",
         %{store_opts: store_opts} do
      key = "r1-bus-#{System.unique_integer([:positive])}"
      handler = "r1-bus-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:ash_a2a, :command_bus, :actuation_commit],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:actuation_commit, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %Receipt{status: :completed}} =
               run(slow_command(key, 0), store_opts,
                 store: AshA2A.Test.Fixture.LostActuationIndexStore,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
      assert_received {:actuation_commit, %{outcome: :failed}}

      # A different command id for the same effect, against the same real
      # Memory store: answered from the claimant's committed primary receipt.
      assert {:ok, %Receipt{}} =
               run(slow_command(key, 0), store_opts,
                 store: AshA2A.ReceiptStore.Memory,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
    end
  end

  describe "OBS-04 pending-dispatch stash hygiene" do
    test "no OCEL pending-dispatch stash survives a run/4 in the calling process",
         %{store_opts: store_opts} do
      command =
        Command.new("AshA2A.Test.Fixture.Echo.read",
          command_id: "obs04-#{System.unique_integer([:positive])}",
          agent_id: "agent-1",
          principal_id: "anonymous",
          input: %{}
        )

      Process.delete(:ash_a2a_ocel_pending_dispatch)

      assert {:ok, _receipt} =
               CommandBus.run(command, data_message(%{}), Echo, store_opts: store_opts)

      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil

      key = "obs04-do-#{System.unique_integer([:positive])}"
      assert {:ok, _} = run(slow_command(key, 1), store_opts, [])
      assert Process.get(:ash_a2a_ocel_pending_dispatch) == nil
    end
  end
end
