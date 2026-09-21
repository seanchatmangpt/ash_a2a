defmodule AshA2A.ActuationIdentityTest do
  @moduledoc """
  RFC-SA2A-001 S55 replay protection.

  Two real stores are exercised against the same claim: the real
  `AshA2A.ReceiptStore.Memory` GenServer, and a real on-disk `EKV` instance
  via `AshA2A.ReceiptStore.Ekv` (same `cluster_size: 1` real-local-EKV setup
  `test/ash_a2a/receipt_store_ekv_test.exs` already uses). The consequence
  being protected is a real counter increment in
  `AshA2A.Test.Fixture.CountingActuator`, so "the effect did not repeat" is a
  state assertion on a real integer, not an interaction assertion.
  """
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Actuation, Command, CommandBus, Identity}
  alias AshA2A.ReceiptStore.Ekv
  alias AshA2A.Test.Fixture.{KeyedActuationCounter, CountingActuator}

  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(KeyedActuationCounter)

    memory = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: memory})

    %{store_opts: [name: memory]}
  end

  defp command(command_id, effect_key, opts \\ []) do
    principal = Identity.principal(Keyword.get(opts, :principal, "s55-principal"))

    authority =
      AshA2A.Authority.new(principal, @capability,
        token_id: "s55-auth",
        constraints: Keyword.get(opts, :constraints, %{})
      )

    Command.new(@capability,
      command_id: command_id,
      agent_id: Keyword.get(opts, :agent_id, "s55-agent"),
      principal_id: principal,
      authority: authority,
      input: %{effect_key: effect_key},
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp run(command, effect_key, store_opts, extra \\ []) do
    CommandBus.run(
      command,
      data_message(%{"effect_key" => effect_key}),
      CountingActuator,
      Keyword.merge([store_opts: store_opts], extra)
    )
  end

  # --- derivation ---------------------------------------------------------

  test "actuation identity is derived from the effect, not from the request id or agent" do
    key = "derive-#{System.unique_integer([:positive])}"

    one = command("cmd-a", key, agent_id: "agent-one")
    two = command("cmd-b", key, agent_id: "agent-two")

    a = Actuation.identity(one)
    b = Actuation.identity(two)

    assert a.actuation_id == b.actuation_id
    assert %Identity{kind: :actuation} = a.actuation_id
    assert a.effect_digest == b.effect_digest

    # A different input is a different effect.
    other = command("cmd-c", "a-different-effect-key")
    refute Actuation.identity(other).actuation_id == a.actuation_id

    # A different principal is a different effect.
    other_principal = command("cmd-d", key, principal: "someone-else")
    refute Actuation.identity(other_principal).actuation_id == a.actuation_id
  end

  test "the idempotency identity binds to the external token when one is supplied" do
    key = "bind-#{System.unique_integer([:positive])}"

    from_metadata = command("cmd-meta", key, metadata: %{idempotency_key: "ext_tok_meta"})
    assert Actuation.identity(from_metadata).idempotency_key.value == "ext_tok_meta"
    assert Actuation.identity(from_metadata).external_token?

    from_string_key = command("cmd-str", key, metadata: %{"idempotency_key" => "ext_tok_str"})
    assert Actuation.identity(from_string_key).idempotency_key.value == "ext_tok_str"

    from_constraints =
      command("cmd-cons", key, constraints: %{external_idempotency_token: "ext_tok_cons"})

    assert Actuation.identity(from_constraints).idempotency_key.value == "ext_tok_cons"

    from_opts = Actuation.identity(command("cmd-opt", key), idempotency_key: "ext_tok_opt")
    assert from_opts.idempotency_key.value == "ext_tok_opt"

    # With no external token the key is still STABLE -- derived from the same
    # effect tuple -- just not shared with any external system.
    plain = command("cmd-plain", key)
    refute Actuation.identity(plain).external_token?

    assert Actuation.identity(plain).idempotency_key ==
             Actuation.identity(command("cmd-plain-retry", key)).idempotency_key
  end

  test "derivation is pure: the same command yields the same pair on every call and process" do
    cmd = command("pure-1", "pure-effect")
    here = Actuation.identity(cmd)
    there = Task.await(Task.async(fn -> Actuation.identity(cmd) end))

    assert here == there
  end

  # --- enforcement against the real Memory store --------------------------

  test "a client retry under a FRESH command id does not repeat the effect (Memory store, :strict)",
       %{store_opts: store_opts} do
    key = "memory-dedup-#{System.unique_integer([:positive])}"
    strict = [actuation_dedup: :strict]

    assert {:ok, first} = run(command("retry-original", key), key, store_opts, strict)
    assert first.terminal_status == :executed
    assert KeyedActuationCounter.count(key) == 1

    # The accident S55 exists for: same effect, brand new command id. The
    # command-id claim cannot see it; the actuation claim can.
    assert {:ok, second} = run(command("retry-fresh-id", key), key, store_opts, strict)

    assert KeyedActuationCounter.count(key) == 1
    assert second.replayed?
    assert second.metadata.outcome == :deduplicated
    assert second.metadata.deduplicated_from_receipt_id == Identity.external(first.receipt_id)
    assert second.metadata.deduplicated_from_command_id == Identity.external(first.command_id)
    assert second.terminal_status == first.terminal_status

    # The dedup receipt is its own receipt for the NEW command id -- it closes
    # that claim rather than leaving it dangling at `receipt: nil`.
    assert second.command_id == Identity.command("retry-fresh-id")

    assert {:ok, fetched} =
             AshA2A.ReceiptStore.Memory.fetch(Identity.command("retry-fresh-id"), store_opts)

    assert fetched.receipt_id == second.receipt_id

    # Ten more fresh-id retries; the real counter still reads 1.
    for n <- 1..10 do
      assert {:ok, _} = run(command("retry-fresh-#{n}", key), key, store_opts, strict)
    end

    assert KeyedActuationCounter.count(key) == 1
  end

  test "the DEFAULT :declared mode does not collapse an undeclared repeat -- and says so", %{
    store_opts: store_opts
  } do
    key = "declared-#{System.unique_integer([:positive])}"

    assert CommandBus.actuation_dedup_mode() == :declared

    assert {:ok, first} = run(command("declared-1", key), key, store_opts)
    assert {:ok, second} = run(command("declared-2", key), key, store_opts)

    # Both really executed. With no client-declared idempotency key, "same
    # capability, same principal, same input, again" is genuinely ambiguous
    # between a dropped-response retry and a second intentional request, and
    # refusing real work on a guess is the worse failure. The identities are
    # still derived and recorded on both receipts -- only enforcement is
    # withheld.
    assert KeyedActuationCounter.count(key) == 2
    assert first.actuation_id == second.actuation_id
    assert first.idempotency_key == second.idempotency_key
    refute second.metadata[:outcome] == :deduplicated

    # Declaring a key on the third call makes the effect enforceable, and a
    # fourth call under that same declared key is refused a second crossing.
    declared = command("declared-3", key, metadata: %{idempotency_key: "declared_token"})
    assert {:ok, _} = run(declared, key, store_opts)
    assert KeyedActuationCounter.count(key) == 3

    declared_retry = command("declared-4", key, metadata: %{idempotency_key: "declared_token"})
    assert {:ok, dedup} = run(declared_retry, key, store_opts)
    assert KeyedActuationCounter.count(key) == 3
    assert dedup.metadata.outcome == :deduplicated
  end

  test "an external idempotency token makes two textually different commands one effect", %{
    store_opts: store_opts
  } do
    key_a = "tok-a-#{System.unique_integer([:positive])}"

    first = command("tok-1", key_a, metadata: %{idempotency_key: "shared_ext_token"})
    assert {:ok, _} = run(first, key_a, store_opts)
    assert KeyedActuationCounter.count(key_a) == 1

    # Same effect content AND the same external token: one actuation.
    second = command("tok-2", key_a, metadata: %{idempotency_key: "shared_ext_token"})
    assert {:ok, receipt} = run(second, key_a, store_opts)

    assert KeyedActuationCounter.count(key_a) == 1
    assert receipt.metadata.outcome == :deduplicated
    assert receipt.idempotency_key.value == "shared_ext_token"
  end

  test "a genuinely different effect is NOT deduplicated", %{store_opts: store_opts} do
    key_one = "distinct-one-#{System.unique_integer([:positive])}"
    key_two = "distinct-two-#{System.unique_integer([:positive])}"

    strict = [actuation_dedup: :strict]
    assert {:ok, one} = run(command("distinct-1", key_one), key_one, store_opts, strict)
    assert {:ok, two} = run(command("distinct-2", key_two), key_two, store_opts, strict)

    assert KeyedActuationCounter.count(key_one) == 1
    assert KeyedActuationCounter.count(key_two) == 1
    refute two.metadata[:outcome] == :deduplicated
    refute one.actuation_id == two.actuation_id
  end

  test "observe commands are never actuation-claimed -- reading twice is not an effect", %{
    store_opts: store_opts
  } do
    one =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "observe-a",
        agent_id: "s55-agent",
        principal_id: "anonymous",
        input: %{}
      )

    two =
      Command.new("AshA2A.Test.Fixture.Echo.read",
        command_id: "observe-b",
        agent_id: "s55-agent",
        principal_id: "anonymous",
        input: %{}
      )

    # Identical effect tuples...
    assert Actuation.identity(one).actuation_id == Actuation.identity(two).actuation_id

    # ...but both really execute, because there is no consequence to protect.
    assert {:ok, first} =
             CommandBus.run(one, data_message(%{}), AshA2A.Test.Fixture.Echo,
               store_opts: store_opts
             )

    assert {:ok, second} =
             CommandBus.run(two, data_message(%{}), AshA2A.Test.Fixture.Echo,
               store_opts: store_opts
             )

    refute second.metadata[:outcome] == :deduplicated
    refute first.receipt_id == second.receipt_id
    # The identities are still RECORDED on observe receipts, just not enforced.
    assert first.actuation_id
    assert first.idempotency_key
  end

  test "an in-flight actuation refuses a concurrent second claimant instead of double-actuating",
       %{store_opts: store_opts} do
    key = "inflight-#{System.unique_integer([:positive])}"
    cmd = command("inflight-1", key)
    actuation = Actuation.identity(cmd)

    # Claim the actuation directly against the real store and never commit it
    # -- exactly the state a crashed-mid-execution claimant leaves behind.
    assert :proceed = AshA2A.ReceiptStore.Memory.claim_actuation(actuation, cmd, store_opts)

    assert {:error, %{code: :actuation_in_flight, receipt: receipt}} =
             run(command("inflight-2", key), key, store_opts, actuation_dedup: :strict)

    assert KeyedActuationCounter.count(key) == 0
    assert receipt.terminal_status == :refused
    assert receipt.status == :failed

    # Releasing the unexecuted claim reopens the effect -- a crashed claimant
    # must not wedge it forever.
    assert :ok = AshA2A.ReceiptStore.Memory.release_actuation(actuation, store_opts)
    assert {:ok, _} = run(command("inflight-3", key), key, store_opts, actuation_dedup: :strict)
    assert KeyedActuationCounter.count(key) == 1
  end

  test "release_actuation refuses to reopen an already-executed effect", %{store_opts: store_opts} do
    key = "no-reopen-#{System.unique_integer([:positive])}"
    cmd = command("no-reopen-1", key)

    assert {:ok, _} = run(cmd, key, store_opts, actuation_dedup: :strict)
    assert KeyedActuationCounter.count(key) == 1

    # Releasing a COMMITTED actuation is a no-op: it must not become a way to
    # launder a second execution.
    assert :ok = AshA2A.ReceiptStore.Memory.release_actuation(Actuation.identity(cmd), store_opts)

    assert {:ok, receipt} =
             run(command("no-reopen-2", key), key, store_opts, actuation_dedup: :strict)

    assert KeyedActuationCounter.count(key) == 1
    assert receipt.metadata.outcome == :deduplicated
  end

  # --- enforcement against the real on-disk EKV store ---------------------

  describe "real on-disk EKV store" do
    setup do
      ekv_name = :"ash_a2a_s55_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(System.tmp_dir!(), "ash_a2a_s55_ekv_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(data_dir) end)
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{ekv_opts: [name: ekv_name]}
    end

    test "a fresh-command-id retry is deduplicated by the durable actuation index", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-dedup-#{System.unique_integer([:positive])}"

      assert {:ok, first} =
               run(command("ekv-1", key), key, ekv_opts, store: Ekv, actuation_dedup: :strict)

      assert first.standing == :durable
      assert KeyedActuationCounter.count(key) == 1

      assert {:ok, second} =
               run(command("ekv-2-fresh-id", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
      assert second.metadata.outcome == :deduplicated
      assert second.metadata.deduplicated_from_command_id == Identity.external(first.command_id)
    end

    test "the actuation claim survives in EKV and refuses an in-flight second claimant", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-inflight-#{System.unique_integer([:positive])}"
      cmd = command("ekv-inflight-1", key)
      actuation = Actuation.identity(cmd)

      assert :proceed = Ekv.claim_actuation(actuation, cmd, ekv_opts)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, cmd, ekv_opts)

      assert {:error, %{code: :actuation_in_flight}} =
               run(command("ekv-inflight-2", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 0

      assert :ok = Ekv.release_actuation(actuation, ekv_opts)

      assert {:ok, _} =
               run(command("ekv-inflight-3", key), key, ekv_opts,
                 store: Ekv,
                 actuation_dedup: :strict
               )

      assert KeyedActuationCounter.count(key) == 1
    end

    test "two callers disagreeing about the external token for one effect is a conflict", %{
      ekv_opts: ekv_opts
    } do
      key = "ekv-conflict-#{System.unique_integer([:positive])}"

      first = command("ekv-conf-1", key, metadata: %{idempotency_key: "token_one"})
      second = command("ekv-conf-2", key, metadata: %{idempotency_key: "token_two"})

      # Different external tokens change the effect digest too, so these are
      # different actuations -- the honest outcome, and both really execute.
      assert {:ok, _} = run(first, key, ekv_opts, store: Ekv)
      assert {:ok, _} = run(second, key, ekv_opts, store: Ekv)
      assert KeyedActuationCounter.count(key) == 2

      # A true conflict is the same actuation id held under a different
      # idempotency key, which the store detects directly.
      a = Actuation.identity(first)
      forged = %{a | idempotency_key: Identity.idempotency("a_completely_different_token")}

      assert {:error, :actuation_conflict} = Ekv.claim_actuation(forged, first, ekv_opts)
    end
  end
end
