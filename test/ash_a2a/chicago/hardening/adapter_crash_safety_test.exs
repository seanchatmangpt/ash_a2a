defmodule AshA2A.Test.Hardening.CrashSafeCommandWorker do
  @moduledoc """
  Real `Oban.Worker` reference implementation of the FULL hardened contract
  `AshA2A.Delivery.Oban`'s own moduledoc documents but does not mandate:
  `AshA2A.Delivery.ObanAuthority.reconstruct/2` (restores the original
  `expires_at`) followed by `AshA2A.Delivery.ObanAuthority.verify_live!/3`
  (re-queries the configured `AshA2A.Authority.Broker` for LIVE standing --
  catches a revocation that no enqueue-time timestamp could ever encode)
  BEFORE calling `AshA2A.CommandBus.run/4`.

  Deliberately NOT the same module as `AshA2A.Test.Support.CommandWorker`:
  that module is this repo's already-shipped reference worker and is out of
  this hardening pass's assigned-file scope (`test/support/command_worker.ex`
  is a shared file another cluster owns -- see this file's moduledoc below
  for the real, found gap in it). This worker exists to give the "a worker
  that gates CommandBus.run/4 on verify_live!/3" sentence in
  `AshA2A.Delivery.Oban`'s own moduledoc a real, runnable, tested body
  instead of leaving it as a documented-but-unexercised suggestion.
  """

  use Oban.Worker, queue: :commands, max_attempts: 3

  alias AshA2A.{Command, CommandBus, Delivery.ObanAuthority, SemanticSubject}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    principal_value = raw_value(args["principal_id"])
    capability_id = args["capability_id"]
    store_opts = store_opts(args)

    reconstructed_authority = ObanAuthority.reconstruct(args, principal_value)
    reconstructed_command = reconstruct_command(args, principal_value, reconstructed_authority)

    # A SECOND, subtler gap `verify_live!/3` gating alone introduces (found
    # by this same hardening pass's own redelivery-after-revocation test,
    # not assumed): gating EVERY perform/1 on live broker standing,
    # unconditionally, means a legitimate Oban at-least-once REDELIVERY of a
    # command whose receipt is ALREADY durable gets spuriously refused the
    # instant its principal's grant is revoked AFTER the real consequence
    # already happened -- even though CommandBus.run/4's own claim/2 would
    # have replayed the stored receipt without touching Ash again. Revoking
    # authority must never invalidate evidence of a consequence that
    # already happened. So: peek the receipt store first (cheap, safe --
    # never itself a source of authority) -- an existing receipt means this
    # is redelivery-of-the-already-actuated, and live re-verification is
    # skipped on purpose; CommandBus.run/4 below replays by fingerprint
    # match. No receipt yet means a genuinely fresh (or still in-flight)
    # attempt, which DOES need live standing re-verified before CommandBus
    # ever sees it -- never rely on `Authority.admits?/2`'s own
    # expiry-only check inside `CommandBus.admit/2` for that.
    authority_result =
      case AshA2A.ReceiptStore.Memory.fetch(reconstructed_command.command_id, store_opts) do
        {:ok, _already_durable_receipt} ->
          {:ok, reconstructed_authority}

        :error ->
          ObanAuthority.verify_live!(reconstructed_authority, capability_id, broker_opts(args))
      end

    with {:ok, authority_to_dispatch_with} <- authority_result do
      command = %{reconstructed_command | authority: authority_to_dispatch_with}
      message = A2A.Message.new_user([A2A.Part.Data.new(args["input"] || %{})])

      case CommandBus.run(command, message, AshA2A.Test.Fixture.Item, store_opts: store_opts) do
        {:ok, _receipt} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Test-only plumbing: the real broker/store instance for THIS test run is
  # threaded through job args (a real named GenServer registered under a
  # unique atom per test, never a global/default), exactly the way a real
  # host would carry `:broker`/`:store_opts` through its own worker's static
  # configuration -- multiple concurrent async tests must not share broker
  # or receipt-store state.
  defp broker_opts(%{"__test_broker_name__" => name}) when is_binary(name),
    do: [broker: {AshA2A.Authority.Broker.InMemory, name: String.to_existing_atom(name)}]

  defp broker_opts(_args), do: []

  defp store_opts(%{"__test_store_name__" => name}) when is_binary(name),
    do: [name: String.to_existing_atom(name)]

  defp store_opts(_args), do: []

  defp reconstruct_command(args, principal_value, authority) do
    Command.new(args["capability_id"],
      command_id: raw_value(args["command_id"]),
      agent_id: raw_value(args["agent_id"]),
      principal_id: principal_value,
      task_id: args["task_id"] && raw_value(args["task_id"]),
      input: args["input"] || %{},
      authority: authority,
      semantic_subject: reconstruct_semantic_subject(args),
      metadata: args["metadata"] || %{}
    )
  end

  defp reconstruct_semantic_subject(%{"semantic_subject_graph_digest" => graph_digest} = args)
       when is_binary(graph_digest) do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: graph_digest,
        projection_digest: args["semantic_subject_projection_digest"],
        manufacturer_digest: args["semantic_subject_manufacturer_digest"],
        ephemeral?: Map.get(args, "semantic_subject_ephemeral", true)
      )

    subject
  end

  defp reconstruct_semantic_subject(_args), do: nil

  defp raw_value(external) when is_binary(external) do
    case String.split(external, ":", parts: 2) do
      [_kind, value] -> value
      [value] -> value
    end
  end
end

defmodule AshA2A.Chicago.Hardening.AdapterCrashSafetyTest do
  @moduledoc """
  ARD S26-29/S70 -- real runtime-adapter (Oban) crash-safety hardening.

  Every collaborator here is real, per this workspace's Chicago-style
  testing discipline: a real, dedicated local PostgreSQL instance backing a
  real `oban_jobs` table (`AshA2A.Test.Repo`, migrated via
  `Oban.Migrations.up/0` exactly as
  `test/ash_a2a/oban_delivery_qualification_test.exs` already does), a real
  `Oban` instance, real `Oban.Job` rows inserted through
  `AshA2A.Delivery.Oban.enqueue/3`, real `Oban.Testing.perform_job/2` (Oban's
  own non-mocking test-execution helper -- never a hand-rolled job loop),
  a real `AshA2A.Authority.Broker.InMemory` `GenServer` (issue/revoke go
  through real process state), and a real `AshA2A.CommandBus.run/4` dispatch
  against `AshA2A.Test.Fixture.Item` (ETS-backed, but a genuine Ash data
  layer). `setup_all` checks Postgres reachability for real and raises with
  setup instructions if none is reachable -- matching this repo's own
  established convention -- rather than silently skipping or substituting a
  mock queue.

  ## Two things this file proves

  1. **A worker that follows `AshA2A.Delivery.Oban`'s own documented
     hardened contract (`ObanAuthority.reconstruct/2` +
     `ObanAuthority.verify_live!/3` gating `CommandBus.run/4`) really does
     fail closed** when the principal's broker grant is revoked, or expires,
     in the real gap between `enqueue/3` and `perform/1` -- proven by real
     final ETS-backed state (no `Ash.create` ran), not merely by inspecting
     a refusal tuple. `AshA2A.Test.Hardening.CrashSafeCommandWorker` (this
     file) is that real, runnable reference body.

  2. **A real crash-and-redelivery** (Oban's own at-least-once delivery
     guarantee: the same real DB job row dequeued and attempted a second
     time, replicating what a live queue producer's own dequeue SQL does)
     for a command whose receipt is ALREADY durable never double-actuates --
     exactly one `Ash.create`, exactly one committed `AshA2A.Receipt`,
     proven by real `Ash.read!/2` state after both attempts, matching
     `test/ash_a2a/oban_delivery_qualification_test.exs`'s own established
     replay-on-redelivery proof but exercised here against the hardened
     worker specifically.

  ## Real gap found, and since closed (CLOSED, not still open)

  `AshA2A.Test.Support.CommandWorker` -- this repo's shipped reference
  `Oban.Worker` (`test/support/command_worker.ex`) -- originally called
  `ObanAuthority.reconstruct/2` but never `ObanAuthority.verify_live!/3`.
  `AshA2A.Delivery.Oban`'s own moduledoc states omitting `verify_live!/3` is
  a legal, documented choice, but its real, concrete consequence was that
  the shipped worker failed closed on an EXPIRED authority (expiry alone
  survives `reconstruct/2` + `CommandBus.admit/2`'s own `Authority.admits?/2`
  expiry check) but did NOT fail closed on a REVOKED-but-unexpired
  authority. `test/support/command_worker.ex` now peeks the receipt store
  (skip live re-verification only for redelivery of an already-durable
  receipt -- see that file's own moduledoc for why an unconditional gate
  would itself be a regression) then calls `ObanAuthority.verify_live!/3`
  against the CONFIGURED (default, config-driven) broker before a fresh
  `CommandBus.run/4` dispatch -- the same real contract
  `CrashSafeCommandWorker` above already proved out in this same file. The
  last test below now regression-guards the closed gap, using the real
  default broker (the one `test/support/command_worker.ex` actually
  consults in production, unlike this file's own `CrashSafeCommandWorker`
  reference body, which threads a test-local broker for isolation).
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Command, Delivery, Identity}
  alias AshA2A.Authority.{Broker.InMemory, Grant}
  alias AshA2A.Test.Fixture.{Item, ItemDomain}
  alias AshA2A.Test.Hardening.CrashSafeCommandWorker
  alias AshA2A.Test.Support.CommandWorker

  @oban_name AshA2A.Test.Hardening.Oban
  @capability_id "AshA2A.Test.Fixture.Item.create"

  setup_all do
    ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    start_supervised!(
      {Oban, name: @oban_name, repo: AshA2A.Test.Repo, queues: [], plugins: false}
    )

    :ok
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

    broker_name = :"crash_safety_broker_#{suffix}"
    {:ok, _pid} = start_supervised({InMemory, name: broker_name}, id: {:broker, suffix})
    broker = {InMemory, name: broker_name}

    store_name = Module.concat(__MODULE__, "Store#{suffix}")
    start_supervised!({AshA2A.ReceiptStore.Memory, name: store_name}, id: {:store, suffix})

    %{
      suffix: suffix,
      label: "crash-safety-item-#{suffix}",
      broker: broker,
      broker_name: broker_name,
      store_name: store_name
    }
  end

  # -- 1. Hardened worker fails closed on a REVOKED grant --------------------

  test "a grant revoked between enqueue and perform/1 is refused by the hardened worker, and no Ash.create runs",
       %{
         suffix: suffix,
         label: label,
         broker: broker,
         broker_name: broker_name,
         store_name: store_name
       } do
    subject = Identity.principal("subject-revoke-#{suffix}")
    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command = build_command("crash-revoke-#{suffix}", subject, authority, label)

    assert {:ok, %Delivery{provider_ref: job_id}} =
             enqueue(CrashSafeCommandWorker, command, broker_name, store_name)

    # The real gap this closes: the principal's real broker grant is torn
    # down while the job would have been sitting in the queue -- no time
    # bound was ever set, so this is NOT reducible to an expiry check.
    assert :ok = Grant.revoke(subject, @capability_id, broker: broker)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert {:error, %{reason: :authority_stale}} =
             Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- 2. Hardened worker fails closed on an EXPIRED grant --------------------

  test "a grant whose real expiry passes between enqueue and perform/1 is refused by the hardened worker, and no Ash.create runs",
       %{
         suffix: suffix,
         label: label,
         broker: broker,
         broker_name: broker_name,
         store_name: store_name
       } do
    subject = Identity.principal("subject-expire-#{suffix}")
    # Expires almost immediately -- really in the past by the time perform/1
    # runs below, not a simulated/frozen clock.
    expires_at = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:ok, authority} =
             Grant.grant(subject, @capability_id, broker: broker, expires_at: expires_at)

    command = build_command("crash-expire-#{suffix}", subject, authority, label)

    assert {:ok, %Delivery{provider_ref: job_id}} =
             enqueue(CrashSafeCommandWorker, command, broker_name, store_name)

    # Really wait past the real expiry -- not a mocked clock.
    Process.sleep(1_100)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert {:error, %{reason: :authority_expired}} =
             Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- 3. Positive control: a still-standing grant really actuates -----------

  test "a grant that is still standing at perform/1 time really actuates through the hardened worker",
       %{
         suffix: suffix,
         label: label,
         broker: broker,
         broker_name: broker_name,
         store_name: store_name
       } do
    subject = Identity.principal("subject-standing-#{suffix}")
    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command = build_command("crash-standing-#{suffix}", subject, authority, label)

    assert {:ok, %Delivery{provider_ref: job_id}} =
             enqueue(CrashSafeCommandWorker, command, broker_name, store_name)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)
    assert receipt.status == :completed

    assert [%Item{label: ^label}] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- 4. Crash + redelivery does not double-actuate a durable receipt -------

  test "a real crash-and-redelivery of the same job (Oban's own at-least-once delivery) never double-actuates once the receipt is durable",
       %{
         suffix: suffix,
         label: label,
         broker: broker,
         broker_name: broker_name,
         store_name: store_name
       } do
    subject = Identity.principal("subject-redeliver-#{suffix}")
    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command = build_command("crash-redeliver-#{suffix}", subject, authority, label)

    assert {:ok, %Delivery{provider_ref: job_id}} =
             enqueue(CrashSafeCommandWorker, command, broker_name, store_name)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, first_receipt} =
             AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    assert [%Item{id: created_id}] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))

    # Real redelivery: the same DB job row is dequeued and attempted again --
    # exactly what Oban's own at-least-once semantics do after a crash mid
    # attempt (a real Ecto update bumping attempt/attempted_at, not a
    # fabricated retry). The grant is NOT touched here -- this test isolates
    # "does redelivery double-actuate," not authority staleness (test 1
    # covers that combination separately below).
    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, second_receipt} =
             AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    assert second_receipt.receipt_id == first_receipt.receipt_id
    assert second_receipt.fingerprint == first_receipt.fingerprint

    assert [%Item{id: ^created_id}] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- 5. Redelivery AFTER revocation: durable replay still wins over a live
  #       re-verification that would otherwise refuse -----------------------
  #
  # A subtlety `verify_live!/3` alone cannot see: once a receipt is
  # committed, CommandBus's OWN claim/replay semantics
  # (`AshA2A.ReceiptStore.claim/2`) short-circuit to the stored receipt
  # BEFORE authority is ever re-admitted for the retry -- exactly matching
  # `test/ash_a2a/oban_delivery_qualification_test.exs`'s established
  # "redelivery replays, never re-executes" proof. A revoked grant on a
  # REDELIVERED (already-actuated) command must therefore still replay, not
  # spuriously refuse -- revoking authority must never invalidate evidence
  # of a consequence that ALREADY happened.
  test "revoking the grant after a receipt is already durable does not turn a legitimate redelivery into a spurious refusal, and does not double-actuate",
       %{
         suffix: suffix,
         label: label,
         broker: broker,
         broker_name: broker_name,
         store_name: store_name
       } do
    subject = Identity.principal("subject-revoke-after-#{suffix}")
    assert {:ok, authority} = Grant.grant(subject, @capability_id, broker: broker)

    command = build_command("crash-revoke-after-#{suffix}", subject, authority, label)

    assert {:ok, %Delivery{provider_ref: job_id}} =
             enqueue(CrashSafeCommandWorker, command, broker_name, store_name)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, first_receipt} =
             AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    assert [%Item{id: created_id}] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))

    assert :ok = Grant.revoke(subject, @capability_id, broker: broker)

    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, second_receipt} =
             AshA2A.ReceiptStore.Memory.fetch(command.command_id, name: store_name)

    # NOT `receipt.replayed?` -- verified against
    # `AshA2A.Receipt`'s own struct default (`replayed?: false`) and
    # `AshA2A.CommandBus`'s only two writers of `true`
    # (`close_claim_as_duplicate/7`, the CONCURRENT in-flight dedup path):
    # a sequential `{:replay, receipt}` claim (this scenario -- the receipt
    # is already fully committed by the time redelivery is attempted)
    # returns the ORIGINAL stored receipt unchanged, so `replayed?` stays
    # `false` here too -- matching
    # `oban_delivery_qualification_test.exs`'s own established redelivery
    # assertions, which check `receipt_id`/`fingerprint` identity and real
    # final state, never `replayed?`, for exactly this reason.
    assert second_receipt.receipt_id == first_receipt.receipt_id
    assert second_receipt.fingerprint == first_receipt.fingerprint

    assert [%Item{id: ^created_id}] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- 6. Real, currently-shipped gap in AshA2A.Test.Support.CommandWorker ---
  #
  # Regression guard for the closed gap (state-based, not an interaction
  # check) -- see this file's moduledoc "Real gap found, and since closed".
  # Uses the real DEFAULT (config-driven) broker deliberately, since that
  # is the one `test/support/command_worker.ex` actually consults in
  # production -- unlike `CrashSafeCommandWorker` above, which threads a
  # test-local broker purely for test isolation.
  test "the shipped AshA2A.Test.Support.CommandWorker now re-verifies live broker standing, so a revoked-but-unexpired grant is refused (closed gap, regression guard)",
       %{suffix: suffix, label: label} do
    subject = Identity.principal("subject-shipped-gap-#{suffix}")
    assert {:ok, authority} = Grant.grant(subject, @capability_id)

    command = build_command("crash-shipped-gap-#{suffix}", subject, authority, label)

    # CommandWorker.perform/1 resolves the default AshA2A.ReceiptStore and
    # the default (config-driven) AshA2A.Authority.Broker -- both real,
    # both the ones production actually uses.
    assert {:ok, %Delivery{provider_ref: job_id}} =
             Delivery.Oban.enqueue(CommandWorker, command,
               name: @oban_name,
               job_opts: [queue: :commands]
             )

    assert :ok = Grant.revoke(subject, @capability_id)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    # Real, current, fixed behavior: a refusal, not :ok -- CommandWorker
    # peeks the receipt store (no receipt exists yet for this fresh
    # command), finds none, and calls ObanAuthority.verify_live!/3 against
    # the real default broker before ever reaching CommandBus.run/4.
    # Revocation is now visible because it re-asks the broker for real.
    assert {:error, %{reason: :authority_stale}} =
             Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  # -- Shared helpers ----------------------------------------------------

  defp build_command(command_id, subject, authority, label) do
    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: subject,
      authority: authority,
      input: %{label: label}
    )
  end

  # Threads this test's own uniquely-named broker/store process names
  # through the real, DB-persisted Oban.Job args -- CrashSafeCommandWorker
  # reads them back in perform/1 (see that module's broker_opts/1,
  # store_opts/1). A real production worker would instead resolve its
  # broker/store from static application config, exactly as
  # AshA2A.Test.Support.CommandWorker already does; this test-only plumbing
  # exists so concurrent test cases never share broker/store state.
  defp enqueue(worker, command, broker_name, store_name) do
    payload =
      Delivery.Oban.payload(command)
      |> Map.put("__test_broker_name__", Atom.to_string(broker_name))
      |> Map.put("__test_store_name__", Atom.to_string(store_name))

    job_opts = [worker: worker, queue: :commands]
    changeset = Oban.Job.new(payload, job_opts)

    case Oban.insert(@oban_name, changeset) do
      {:ok, job} ->
        {:ok,
         Delivery.new(:oban, command,
           provider_ref: Map.get(job, :id),
           status: :scheduled,
           metadata: %{worker: worker}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Real dequeue-claim step, replicating what a live Oban queue producer's
  # own dequeue SQL does when it claims an `available` job for execution --
  # matching test/ash_a2a/oban_delivery_qualification_test.exs's own
  # established helper (`attempted_at`/`attempt` are real columns
  # `Oban.Testing.perform_job/2`'s `record_finished/1` requires to be
  # non-nil).
  defp dequeue!(%Oban.Job{} = job) do
    job
    |> Ecto.Changeset.change(attempted_at: DateTime.utc_now(), attempt: job.attempt + 1)
    |> AshA2A.Test.Repo.update!()
  end

  defp apply_oban_migration! do
    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  # Same real reachability probe as
  # test/ash_a2a/oban_delivery_qualification_test.exs -- checked for real
  # (a real Postgrex.start_link/1 attempt against config/test.exs's own
  # AshA2A.Test.Repo connection opts), raising with setup instructions
  # rather than crashing opaquely if no local Postgres is reachable.
  defp ensure_postgres_reachable! do
    repo_config = Application.fetch_env!(:ash_a2a, AshA2A.Test.Repo)

    connect_opts = [
      hostname: Keyword.fetch!(repo_config, :hostname),
      port: Keyword.fetch!(repo_config, :port),
      username: Keyword.fetch!(repo_config, :username),
      password: Keyword.fetch!(repo_config, :password),
      database: Keyword.fetch!(repo_config, :database),
      timeout: 2_000,
      connect_timeout: 2_000
    ]

    case Postgrex.start_link(connect_opts) do
      {:ok, pid} ->
        GenServer.stop(pid)
        :ok

      {:error, reason} ->
        raise """
        Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
        for AshA2A.Test.Repo (test/ash_a2a/chicago/hardening/adapter_crash_safety_test.exs).
        Reason: #{inspect(reason)}

        This test needs a real, dedicated local Postgres instance to create
        and query Oban's real `oban_jobs` table against (ARD S26-29/S70
        runtime-adapter crash-safety hardening -- Chicago-style discipline:
        no mocked queue, no stubbed DB). Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: mix test test/ash_a2a/chicago/hardening/adapter_crash_safety_test.exs
        """
    end
  end
end
