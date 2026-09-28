defmodule AshA2A.Rfc004AuthorityEffectKillTest.TripOnConfirmStore do
  @moduledoc """
  A real `AshA2A.ReceiptStore` (it delegates every callback to the real
  `ReceiptStore.Memory`) that additionally trips a real `AshA2A.KillSwitch`
  class at `confirm_claim/3` -- the store call that runs strictly AFTER the
  bus's initial kill-switch check and the pre-DO anchor, and strictly BEFORE
  DO. It is how a test puts an operator's "trip" in the pre-DO window without
  faking the bus.
  """
  @behaviour AshA2A.ReceiptStore

  alias AshA2A.ReceiptStore.Memory

  @impl true
  defdelegate claim(command, opts), to: Memory
  @impl true
  defdelegate commit(receipt, opts), to: Memory
  @impl true
  defdelegate fetch(command_id, opts), to: Memory
  @impl true
  defdelegate claim_actuation(actuation, command, opts), to: Memory
  @impl true
  defdelegate commit_actuation(actuation, receipt, opts), to: Memory
  @impl true
  defdelegate release_actuation(actuation, opts), to: Memory

  @impl true
  def confirm_claim(command_id, execution_id, opts) do
    :ok = AshA2A.KillSwitch.trip(Keyword.fetch!(opts, :trip_class), :tripped_pre_do)
    Memory.confirm_claim(command_id, execution_id, opts)
  end
end

defmodule AshA2A.Rfc004AuthorityEffectKillTest.NoVerifyBroker do
  @moduledoc "A module that is a broker in name only: exports neither verify/2 nor granted?/3."
  def issue(_subject, _capability, _opts), do: {:error, :never}
end

defmodule AshA2A.Rfc004AuthorityEffectKillTest do
  @moduledoc """
  RFC-SA2A-004 S10/S11 witnesses, real collaborators only: the real
  `AshA2A.Authority.Broker.InMemory` (configured in config/test.exs), the real
  `AshA2A.KillSwitch`, the real Memory receipt store, and the real
  `CountingActuator` whose counter is the state assertion for "DO did not run".
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Authority, Command, CommandBus, Identity, KillSwitch}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Test.Fixture.{CountingActuator, KeyedActuationCounter}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])

    on_exit(fn ->
      Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms)
      Application.delete_env(:ash_a2a, :kill_switch_class)
    end)

    start_supervised!(KeyedActuationCounter)
    memory = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: memory})
    %{store_opts: [name: memory]}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp command(command_id, key, authority_opts) do
    principal = Identity.principal("rfc004-principal")
    authority = Authority.new(principal, @capability, authority_opts)

    Command.new(@capability,
      command_id: command_id,
      agent_id: "rfc004-agent",
      principal_id: principal,
      authority: authority,
      input: %{effect_key: key}
    )
  end

  defp run(command, key, store_opts, extra \\ []) do
    CommandBus.run(
      command,
      data_message(%{"effect_key" => key}),
      CountingActuator,
      Keyword.merge([store_opts: store_opts], extra)
    )
  end

  test "authority revoked at the broker before DO is refused with a typed refusal and DO never runs",
       %{store_opts: store_opts} do
    key = uniq("revoked")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    # Struct-level admission still passes (unexpired, matching); only the
    # authoritative broker knows the grant is gone.
    assert Authority.admits?(cmd.authority, cmd)
    assert :ok = InMemory.revoke(cmd.authority)

    assert {:error, %{code: :authority_revoked, receipt: receipt}} = run(cmd, key, store_opts)
    assert KeyedActuationCounter.count(key) == 0
    assert receipt.command_id == cmd.command_id

    # The claim was closed with a receipt, so it is not left in flight.
    assert {:ok, stored} = AshA2A.ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
    assert stored.receipt_id == receipt.receipt_id
  end

  test "an already-expired authority is refused at initial admission and DO never runs", %{
    store_opts: store_opts
  } do
    key = uniq("expired")

    cmd =
      command(uniq("cmd"), key,
        token_id: uniq("tok"),
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:error, %{code: code}} = run(cmd, key, store_opts)
    assert code in [:authority_mismatch, :authority_expired]
    assert KeyedActuationCounter.count(key) == 0
  end

  test "a declared authority input constraint the command does not satisfy is refused at admission",
       %{store_opts: store_opts} do
    key = uniq("constraint")

    wrong = command(uniq("cmd"), key, constraints: %{input: %{effect_key: "someone-else"}})
    assert {:error, %{code: :authority_mismatch}} = run(wrong, key, store_opts)
    assert KeyedActuationCounter.count(key) == 0

    right = command(uniq("cmd"), key, constraints: %{input: %{effect_key: key}})
    assert {:ok, receipt} = run(right, key, store_opts)
    assert receipt.terminal_status == :executed
    assert KeyedActuationCounter.count(key) == 1
  end

  test "a fresh request (new command id) for the same effect cannot cross DO twice under the default mode",
       %{store_opts: store_opts} do
    key = uniq("dup")
    assert CommandBus.actuation_dedup_mode() == :strict

    assert {:ok, _} = run(command(uniq("a"), key, token_id: "dup-auth"), key, store_opts)
    assert {:ok, second} = run(command(uniq("b"), key, token_id: "dup-auth"), key, store_opts)

    assert KeyedActuationCounter.count(key) == 1
    assert second.metadata.outcome == :deduplicated
  end

  test "kill switch named only via Application env refuses the CommandBus path", %{
    store_opts: store_opts
  } do
    class = uniq("env-class")
    Application.put_env(:ash_a2a, :kill_switch_class, class)
    assert :ok = KillSwitch.trip(class, :incident_env)

    key = uniq("ks")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    assert {:error, %{code: :kill_switch_tripped, detail: :incident_env}} =
             run(cmd, key, store_opts)

    assert KeyedActuationCounter.count(key) == 0
    assert :error = AshA2A.ReceiptStore.Memory.fetch(cmd.command_id, store_opts)
  end

  test "un-tripped env kill switch class lets the command proceed", %{store_opts: store_opts} do
    class = uniq("env-clear")
    Application.put_env(:ash_a2a, :kill_switch_class, class)

    key = uniq("ks-clear")
    assert {:ok, _} = run(command(uniq("cmd"), key, token_id: uniq("tok")), key, store_opts)
    assert KeyedActuationCounter.count(key) == 1
  end

  test "kill switch tripped AFTER the initial check but BEFORE DO is re-checked and refuses with zero DO",
       %{store_opts: store_opts} do
    class = uniq("trip-window")
    key = uniq("ks-window")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    # Untripped at admission: the initial check passes. The store trips the
    # class during confirm_claim, i.e. inside the pre-DO window.
    refute KillSwitch.tripped?(class)

    assert {:error, %{code: :kill_switch_tripped, receipt: receipt}} =
             CommandBus.run(
               cmd,
               data_message(%{"effect_key" => key}),
               CountingActuator,
               store: AshA2A.Rfc004AuthorityEffectKillTest.TripOnConfirmStore,
               store_opts: Keyword.put(store_opts, :trip_class, class),
               kill_switch_class: class
             )

    assert KillSwitch.tripped?(class)
    assert KeyedActuationCounter.count(key) == 0
    assert receipt.command_id == cmd.command_id
  end

  test "a broker that cannot be consulted before DO fails closed with :authority_revalidation_unavailable",
       %{store_opts: store_opts} do
    # (a) a module exporting neither verify/2 nor granted?/3
    key = uniq("noverify")
    cmd = command(uniq("cmd"), key, token_id: uniq("tok"))

    assert {:error, %{code: :authority_revalidation_unavailable, receipt: %{}}} =
             run(cmd, key, store_opts,
               authority_broker: AshA2A.Rfc004AuthorityEffectKillTest.NoVerifyBroker
             )

    assert KeyedActuationCounter.count(key) == 0

    # (b) a real InMemory broker whose process is not running (GenServer exit)
    key2 = uniq("deadbroker")
    cmd2 = command(uniq("cmd"), key2, token_id: uniq("tok"))

    assert {:error, %{code: :authority_revalidation_unavailable}} =
             run(cmd2, key2, store_opts,
               authority_broker: {InMemory, [name: :rfc004_no_such_broker_process]}
             )

    assert KeyedActuationCounter.count(key2) == 0
  end

  test "a STANDING broker grant is revalidated with granted?/3: proceeds while standing, refused once revoked",
       %{store_opts: store_opts} do
    subject = Identity.principal(uniq("standing-principal"))
    assert {:ok, _} = AshA2A.Authority.Grant.grant(subject, @capability)

    authority = AshA2A.Authority.Grant.authorize(subject.value, @capability)
    assert authority.admitted_by

    build = fn id, key ->
      Command.new(@capability,
        command_id: id,
        agent_id: "rfc004-agent",
        principal_id: subject,
        authority: authority,
        input: %{effect_key: key}
      )
    end

    key1 = uniq("standing-ok")
    assert {:ok, receipt} = run(build.(uniq("cmd"), key1), key1, store_opts)
    assert receipt.terminal_status == :executed
    assert KeyedActuationCounter.count(key1) == 1

    assert :ok = AshA2A.Authority.Grant.revoke(subject, @capability)

    key2 = uniq("standing-revoked")

    assert {:error, %{code: :authority_revoked}} =
             run(build.(uniq("cmd"), key2), key2, store_opts)

    assert KeyedActuationCounter.count(key2) == 0
  end
end
