defmodule AshA2A.Chicago.Hardening.ConcurrencyRacesTest do
  @moduledoc """
  Real BEAM concurrency-race hardening for the mechanisms named in this
  session's RFC-SA2A-001 S55 / ARD S40 work: `AshA2A.CommandBus`,
  `AshA2A.ReceiptOutbox`, `AshA2A.Authority.Broker` (`InMemory`), and
  `AshA2A.ReceiptStore.ActuationClaimLease`.

  Chicago style throughout: no `Mox`/`:meck`/`Mock(`/`monkeypatch` anywhere in
  this file. Every race is forced with real `Task.async_stream/3` /
  `Task.async/1` processes -- genuine concurrent BEAM schedulers, not
  simulated interleaving -- against a real, supervised
  `AshA2A.ReceiptStore.Memory` `GenServer` and a real, supervised
  `AshA2A.Authority.Broker.InMemory` `GenServer`. "The effect did not repeat"
  is proved on a real, observable side-effect counter
  (`AshA2A.Test.Fixture.KeyedActuationCounter`, the same fixture
  `test/ash_a2a_actuation_identity_test.exs` uses), not on receipts alone --
  receipts prove what `CommandBus` *reported*; the counter proves what
  actually happened underneath.

  ## What this file covers that no existing test does

  `test/ash_a2a_command_bus_concurrency_test.exs` already proves the primary
  command-id claim race (identical content, same command_id) against a real
  `Ash.create` on `AshA2A.Test.Fixture.Item` under real `Task.async_stream/3`
  concurrency. `test/ash_a2a_actuation_identity_test.exs` already proves the
  RFC-SA2A-001 S55 actuation-claim index's *logic* (fresh-command-id retry
  dedup, `:strict`/`:declared`/`:off` modes) -- but every one of those calls
  runs strictly sequentially, one full `CommandBus.run/4` awaited before the
  next begins. Nothing in the existing suite has ever put genuinely
  concurrent BEAM processes against `AshA2A.ReceiptStore.Memory`'s
  `{:claim_actuation, ...}` mailbox clause, nor against
  `AshA2A.Authority.Broker.InMemory`'s `{:issue, ...}` / `{:revoke, ...}`
  clauses. This file adds exactly that, plus the one command-id-claim shape
  the existing concurrency file also does not cover: two *different* real
  command contents racing the identical `command_id` (`:command_conflict`
  under real concurrent load, not just sequentially).

  ## Real finding

  No new race was found. Every mechanism exercised here is backed by a real
  `GenServer` whose single mailbox already serializes the decision in
  question (the primary command claim, the S55 actuation claim, and the
  broker's issue/revoke/verify state), so genuine concurrent load converges
  to the same single-winner outcome a sequential trace would produce -- this
  file exists to prove that holds under real adversarial concurrency, not to
  assume it from reading the source. A clean bill of health across four
  independent adversarial scenarios (below) is itself the hardening result.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  import AshA2A.Test.MessageHelpers

  alias AshA2A.{Actuation, Authority, Command, CommandBus, Identity}
  alias AshA2A.Authority.Broker.InMemory
  alias AshA2A.Authority.Grant
  alias AshA2A.ReceiptStore.Memory
  alias AshA2A.Test.Fixture.{CountingActuator, KeyedActuationCounter}

  @concurrency 40
  @capability "AshA2A.Test.Fixture.CountingActuator.actuate"

  setup do
    # Retries kept fast (default [50, 150]ms) -- these tests do not expect
    # any real commit failure, but a fast-fail keeps a genuine one from
    # silently inflating this file's own runtime.
    Application.put_env(:ash_a2a, :receipt_commit_retry_delays_ms, [1, 1])
    on_exit(fn -> Application.delete_env(:ash_a2a, :receipt_commit_retry_delays_ms) end)

    start_supervised!(KeyedActuationCounter)

    store_name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    start_supervised!({Memory, name: store_name})

    %{store_opts: [name: store_name]}
  end

  defp effect_command(command_id, effect_key, opts \\ []) do
    principal = Identity.principal(Keyword.get(opts, :principal, "races-principal"))

    authority =
      Authority.new(principal, @capability,
        token_id: Keyword.get(opts, :token_id, "races-auth-#{command_id}"),
        constraints: Keyword.get(opts, :constraints, %{})
      )

    Command.new(@capability,
      command_id: command_id,
      agent_id: Keyword.get(opts, :agent_id, "races-agent"),
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

  # --- 1. same command_id, identical content ------------------------------

  describe "CommandBus.run/4: same command_id, identical content" do
    test "N real concurrent processes racing the identical command_id converge to exactly one real actuation, replay for the rest",
         %{store_opts: store_opts} do
      key = "same-content-#{System.unique_integer([:positive])}"
      command_id = "races-same-#{System.unique_integer([:positive])}"
      # One real `Command` struct, shared by reference across every
      # concurrent task -- guarantees byte-identical semantic content (and
      # therefore an identical fingerprint) the same way
      # `ash_a2a_command_bus_concurrency_test.exs` does.
      command = effect_command(command_id, key)

      results =
        1..@concurrency
        |> Task.async_stream(
          fn _ -> run(command, key, store_opts, actuation_dedup: :strict) end,
          max_concurrency: @concurrency,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == @concurrency

      executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
      replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
      refused = Enum.filter(results, &match?({:error, _}, &1))

      assert length(executed) == 1
      [{:ok, executor}] = executed
      assert executor.status == :completed
      assert executor.consequence == :external_do
      refute executor.replayed?

      for {:ok, replay} <- replayed do
        assert replay.receipt_id == executor.receipt_id
        assert replay.fingerprint == executor.fingerprint
      end

      for {:error, reason} <- refused do
        assert reason.code == :in_flight
      end

      assert length(executed) + length(replayed) + length(refused) == @concurrency

      # Real, observable proof independent of the receipts returned: the
      # side effect ran exactly once.
      assert KeyedActuationCounter.count(key) == 1

      # A caller arriving strictly after the race has fully settled gets a
      # faithful replay, never a second real actuation.
      assert {:ok, post} = run(command, key, store_opts, actuation_dedup: :strict)
      assert post.replayed?
      assert post.receipt_id == executor.receipt_id
      assert KeyedActuationCounter.count(key) == 1
    end
  end

  # --- 2. same command_id, genuinely different content ---------------------

  describe "CommandBus.run/4: same command_id, different content" do
    test "N real concurrent processes racing the SAME command_id with genuinely different content refuse conflict, never double-actuate",
         %{store_opts: store_opts} do
      command_id = "races-conflict-#{System.unique_integer([:positive])}"
      key_a = "conflict-a-#{System.unique_integer([:positive])}"
      key_b = "conflict-b-#{System.unique_integer([:positive])}"

      command_a = effect_command(command_id, key_a)
      command_b = effect_command(command_id, key_b)

      # Sanity on the premise itself: these really are two different
      # semantic commands, not two references to the same content.
      refute command_a.fingerprint == command_b.fingerprint
      assert command_a.command_id == command_b.command_id

      half = div(@concurrency, 2)

      # Interleaved/shuffled so real scheduling does not happen to run every
      # A before every B -- both contents are genuinely racing the same
      # command_id concurrently.
      tasks =
        (List.duplicate({key_a, command_a}, half) ++ List.duplicate({key_b, command_b}, half))
        |> Enum.shuffle()

      results =
        tasks
        |> Task.async_stream(fn {key, command} -> run(command, key, store_opts) end,
          max_concurrency: length(tasks),
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == @concurrency

      executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
      replayed = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))
      conflicts = Enum.filter(results, &match?({:error, %{code: :command_conflict}}, &1))
      in_flight = Enum.filter(results, &match?({:error, %{code: :in_flight}}, &1))

      # The core invariant: never both A's and B's effects actuate under the
      # same command_id -- exactly one real execution total, whichever
      # content happened to win the real race.
      assert length(executed) == 1
      [{:ok, executor}] = executed

      {winner_key, winner_command, loser_key, loser_command} =
        if executor.fingerprint == command_a.fingerprint,
          do: {key_a, command_a, key_b, command_b},
          else: {key_b, command_b, key_a, command_a}

      # The winning content's real counter incremented exactly once...
      assert KeyedActuationCounter.count(winner_key) == 1
      # ...and the losing content's real counter never incremented at all --
      # it was refused as a conflict, not silently actuated too.
      assert KeyedActuationCounter.count(loser_key) == 0

      for {:ok, replay} <- replayed do
        assert replay.receipt_id == executor.receipt_id
        assert replay.fingerprint == executor.fingerprint
      end

      for {:error, reason} <- conflicts do
        assert reason.code == :command_conflict
      end

      for {:error, reason} <- in_flight do
        assert reason.code == :in_flight
      end

      assert length(executed) + length(replayed) + length(conflicts) + length(in_flight) ==
               @concurrency

      # A post-race caller presenting the LOSING content is permanently
      # refused as a conflict -- never silently actuated later.
      assert {:error, %{code: :command_conflict}} = run(loser_command, loser_key, store_opts)
      assert KeyedActuationCounter.count(loser_key) == 0

      # A post-race caller presenting the WINNING content gets a faithful
      # replay, never a second actuation.
      assert {:ok, post} = run(winner_command, winner_key, store_opts)
      assert post.replayed?
      assert post.receipt_id == executor.receipt_id
      assert KeyedActuationCounter.count(winner_key) == 1
    end
  end

  # --- 3. RFC-SA2A-001 S55 actuation-claim index under real concurrency ----

  describe "RFC-SA2A-001 S55 actuation-claim index under real concurrency" do
    test "N real concurrent processes with DISTINCT command_ids but the identical effect race the actuation-claim index: exactly one real actuation, never a double actuation",
         %{store_opts: store_opts} do
      key = "s55-race-#{System.unique_integer([:positive])}"
      strict = [actuation_dedup: :strict]

      # Every command below has its OWN distinct command_id, so the PRIMARY
      # command-id claim `Memory.claim/2` cannot protect this race at all --
      # each of the @concurrency processes independently wins its own
      # primary claim (`{:execute, _}`) and proceeds into
      # `CommandBus.execute_claimed/9`, converging concurrently on the SAME
      # `{:claim_actuation, ...}` mailbox entry (same effect => same
      # `AshA2A.Actuation` identity => same idempotency key). This is the
      # one real gap `test/ash_a2a_actuation_identity_test.exs` documents
      # only sequentially (one retry at a time).
      commands =
        for n <- 1..@concurrency do
          effect_command("s55-race-cmd-#{n}-#{System.unique_integer([:positive])}", key)
        end

      actuation_ids = commands |> Enum.map(&Actuation.identity/1) |> Enum.map(& &1.actuation_id)
      assert length(Enum.uniq(actuation_ids)) == 1

      results =
        commands
        |> Task.async_stream(fn command -> run(command, key, store_opts, strict) end,
          max_concurrency: @concurrency,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == @concurrency

      executed = Enum.filter(results, &match?({:ok, %{replayed?: false}}, &1))
      deduplicated = Enum.filter(results, &match?({:ok, %{replayed?: true}}, &1))

      in_flight_refused =
        Enum.filter(results, &match?({:error, %{code: :actuation_in_flight}}, &1))

      # Exactly one caller actually reached DO for this effect...
      assert length(executed) == 1
      [{:ok, executor}] = executed
      refute executor.replayed?

      # ...every other caller either landed a real dedup receipt closing its
      # OWN command-id claim without repeating the effect (arrived after the
      # winner committed), or a typed, pre-DO `:actuation_in_flight` refusal
      # (arrived while the winner was still mid-flight) -- never anything
      # else, and never a second real actuation.
      for {:ok, receipt} <- deduplicated do
        assert receipt.metadata.outcome == :deduplicated

        assert receipt.metadata.deduplicated_from_receipt_id ==
                 Identity.external(executor.receipt_id)
      end

      for {:error, reason} <- in_flight_refused do
        assert reason.code == :actuation_in_flight
      end

      assert length(executed) + length(deduplicated) + length(in_flight_refused) == @concurrency

      # Real, observable proof: the counter incremented exactly once no
      # matter how many distinct command_ids raced the identical effect.
      assert KeyedActuationCounter.count(key) == 1

      # A fresh command_id after the race has fully settled is deduplicated
      # too, never a second actuation.
      post_command =
        effect_command("s55-race-post-#{System.unique_integer([:positive])}", key)

      assert {:ok, post} = run(post_command, key, store_opts, strict)
      assert post.replayed?
      assert post.metadata.outcome == :deduplicated
      assert KeyedActuationCounter.count(key) == 1
    end
  end

  # --- 4. Authority.Broker.InMemory: concurrent issue/reload/revoke --------

  describe "AshA2A.Authority.Broker.InMemory: concurrent grant issue/reload/revoke" do
    setup do
      broker_name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
      start_supervised!({InMemory, name: broker_name})

      %{
        grant_opts: [broker: {InMemory, [name: broker_name]}],
        name_opts: [name: broker_name]
      }
    end

    test "N real concurrent Grant.grant/3 calls for the identical (subject, capability) converge to exactly one real issued grant, every other caller cleanly refused",
         %{grant_opts: grant_opts} do
      principal = Identity.principal("broker-race-issue-#{System.unique_integer([:positive])}")

      results =
        1..@concurrency
        |> Task.async_stream(fn _ -> Grant.grant(principal, @capability, grant_opts) end,
          max_concurrency: @concurrency,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == @concurrency

      issued = Enum.filter(results, &match?({:ok, %Authority{}}, &1))
      refused = Enum.filter(results, &match?({:error, %{reason: :token_id_taken}}, &1))

      # Exactly one real winner -- never two distinct standing grants
      # silently minted under the same deterministic token id.
      assert length(issued) == 1
      [{:ok, winner}] = issued
      assert winner.subject == principal
      assert winner.capability_id == @capability

      assert length(refused) == @concurrency - 1

      for {:error, reason} <- refused do
        assert reason.reason == :token_id_taken
        assert reason.token_id == winner.token_id
      end

      # Real state proof, independent of the per-call results: exactly one
      # standing grant exists afterward.
      assert Grant.granted?(principal, @capability, grant_opts)
      assert {:ok, [%{capability_id: @capability}]} = Grant.list_grants(principal, grant_opts)
    end

    test "a real revoke racing many concurrent granted?/verify reads is never observed as re-admitting: no read ever flips back to standing after falling",
         %{grant_opts: grant_opts, name_opts: name_opts} do
      principal = Identity.principal("broker-race-revoke-#{System.unique_integer([:positive])}")

      assert {:ok, authority} = Grant.grant(principal, @capability, grant_opts)
      assert Grant.granted?(principal, @capability, grant_opts)
      assert {:ok, ^authority} = InMemory.verify(authority, name_opts)

      pollers = 24
      poll_iterations = 250

      poller = fn ->
        for _ <- 1..poll_iterations do
          granted? = Grant.granted?(principal, @capability, grant_opts)
          verified? = match?({:ok, _}, InMemory.verify(authority, name_opts))
          {granted?, verified?}
        end
      end

      # The single revoke is shuffled into the SAME batch of concurrent
      # tasks as every poller (the same real-scheduling-interleave pattern
      # `Enum.shuffle/1` already uses above) rather than fired separately,
      # so the real BEAM scheduler decides the actual interleaving -- this
      # file does not assume the revoke lands mid-poll, it gives the
      # scheduler every chance to place it there.
      tasks =
        (List.duplicate({:poll, poller}, pollers) ++
           [{:revoke, fn -> Grant.revoke(principal, @capability, grant_opts) end}])
        |> Enum.shuffle()

      results =
        tasks
        |> Task.async_stream(fn {tag, fun} -> {tag, fun.()} end,
          max_concurrency: length(tasks),
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [:ok] = for({:revoke, result} <- results, do: result)
      sequences = for {:poll, sequence} <- results, do: sequence
      assert length(sequences) == pollers

      # Monotonicity, checked independently for `granted?/3` and for
      # `verify/2`: once a poller's own sequence observes a fall to
      # refused, it must never observe standing/verified again afterward --
      # a resurrection here would mean the broker's real GenServer state
      # (or a caller reading it) is not actually linearized the way a
      # single-mailbox implementation promises.
      assert_no_resurrection!(sequences, fn {granted?, _verified?} -> granted? end)
      assert_no_resurrection!(sequences, fn {_granted?, verified?} -> verified? end)

      # Real final state, once every poller and the revoke have completed:
      # permanently refused, never standing again.
      refute Grant.granted?(principal, @capability, grant_opts)
      assert {:error, _reason} = InMemory.verify(authority, name_opts)
      assert {:ok, []} = Grant.list_grants(principal, grant_opts)
    end
  end

  # A `sequence` is a list of `{granted?, verified?}` (or a plain boolean
  # list, via `projector`) pairs recorded by ONE real poller process across
  # real time. `projector` extracts the boolean of interest. The real
  # invariant a revoke enforces is monotonic: `true`* `false`* -- once
  # `false` is observed, every later observation in THAT SAME process's real
  # program order must also be `false`. Never asserts WHERE the flip
  # happens (that depends on real, non-deterministic scheduling); only that
  # it happens at most once and never reverses.
  defp assert_no_resurrection!(sequences, projector) do
    for sequence <- sequences do
      values = Enum.map(sequence, projector)

      case Enum.find_index(values, &(&1 == false)) do
        nil ->
          # This poller's own real Task never observed a `false`, e.g. it
          # ran to completion strictly before the revoke's real
          # `GenServer.call` was scheduled -- a legitimate concurrent
          # outcome, not a gap in coverage. Its observations were then
          # consistently `true` throughout.
          assert Enum.all?(values, & &1)

        first_false_index ->
          after_first_false = Enum.drop(values, first_false_index)
          assert Enum.all?(after_first_false, &(&1 == false))
      end
    end
  end
end
