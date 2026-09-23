defmodule AshA2A.ObanDeliveryQualificationTest do
  @moduledoc """
  GAP D -- real Oban integration qualification.

  `test/ash_a2a/oban_delivery_test.exs` only ever exercised
  `AshA2A.Delivery.new/3` and `AshA2A.Delivery.Oban.payload/1` -- pure
  functions over plain structs/maps. `AshA2A.Delivery.Oban.enqueue/3`, the
  only function that actually touches a real `Oban.Job`/`Oban`, was never
  called by any test in this repo (nor was `Oban` a resolvable dependency
  at all until this same release cycle's `feat(deps)` commit).

  This file proves, against a real PostgreSQL-backed `oban_jobs` table and
  a real `Oban` instance (no mocked queue, no stubbed job execution, per
  this workspace's Chicago-style testing discipline):

    1. `AshA2A.Delivery.Oban.available?/0` is real `true` now that `oban`
       is a resolvable dependency.
    2. `enqueue/3` real-inserts a real `Oban.Job` row, carrying a real
       `AshA2A.Command`'s serialized content as `args` -- confirmed by
       querying `oban_jobs` directly through `AshA2A.Test.Repo`, not by
       trusting `enqueue/3`'s own return value alone.
    3. Queue acceptance is not an execution receipt: immediately after
       `enqueue/3` succeeds, no `AshA2A.Receipt` exists yet for that
       command in the default `AshA2A.ReceiptStore.Memory`.
    4. A real `AshA2A.Test.Support.CommandWorker` (`Oban.Worker`), run
       through `Oban.Testing.perform_job/2` (Oban's own real,
       non-mocking test-execution helper -- no hand-rolled job loop),
       reconstructs the real `AshA2A.Command` from the job's real,
       DB-persisted `args` and calls `AshA2A.CommandBus.run/4`, which
       performs a real `Ash.create` against
       `AshA2A.Test.Fixture.Item` (ETS-backed, but a genuine Ash data
       layer, not a fixture double) and commits a real `AshA2A.Receipt`.
    5. Running that same worker's `perform/1` a second time for the
       identical command (Oban's own at-least-once delivery semantics: a
       job may legitimately be re-attempted) replays the already-committed
       receipt instead of re-executing the `Ash.create` a second time --
       proven by the real final state (`Ash.read!/2` against the fixture's
       real ETS-backed records), not merely by inspecting receipt
       bookkeeping.

  Needs a real, reachable PostgreSQL instance for `AshA2A.Test.Repo`
  (`config/test.exs`); `setup_all` checks that for real and raises with
  setup instructions (matching this repo's own `hddl_cli binary not built
  at ...` raise-with-instructions convention,
  `test/support/semantic_hddl_verification.ex`) rather than crashing
  opaquely if a future run has none reachable. The Ash-domain side
  (`AshA2A.Test.Fixture.Item`'s ETS data layer, `AshA2A.CommandBus`,
  `AshA2A.ReceiptStore.Memory`) needs no Postgres at all -- only the real
  `oban_jobs` table this test inserts into and reads back from does.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.{Command, Delivery, Identity, SemanticSubject}
  alias AshA2A.Authority.Grant
  alias AshA2A.Test.Fixture.{Item, ItemDomain}
  alias AshA2A.Test.Support.CommandWorker

  @oban_name AshA2A.Test.Oban
  @capability_id "AshA2A.Test.Fixture.Item.create"

  setup_all do
    repo_config = ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    start_supervised!(
      {Oban, name: @oban_name, repo: AshA2A.Test.Repo, queues: [], plugins: false}
    )

    %{repo_config: repo_config}
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
    %{suffix: suffix, label: "oban-qual-item-#{suffix}"}
  end

  test "AshA2A.Delivery.Oban.available?/0 is real true now that oban is a resolvable dep" do
    assert Delivery.Oban.available?() == true
  end

  test "enqueue/3 real-inserts a real Oban.Job row carrying a real Command, and no receipt exists yet",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{} = delivery} = enqueue(command)

    assert delivery.provider == :oban
    assert delivery.status == :scheduled
    assert is_integer(delivery.provider_ref)

    # Confirmed by querying the real oban_jobs table directly -- not by
    # trusting enqueue/3's own return value alone.
    job = AshA2A.Test.Repo.get!(Oban.Job, delivery.provider_ref)

    assert job.worker == "AshA2A.Test.Support.CommandWorker"
    assert job.state == "available"
    assert job.queue == "commands"
    assert job.args["capability_id"] == @capability_id
    assert job.args["command_id"] == Identity.external(command.command_id)
    assert job.args["principal_id"] == Identity.external(command.principal_id)
    assert job.args["authority_token_id"] == Identity.external(command.authority.token_id)
    assert job.args["input"] == %{"label" => label}
    assert job.args["fingerprint"] == command.fingerprint

    # Queue acceptance != execution receipt: the job was really accepted
    # (real DB row, confirmed above), but the command has not been
    # admitted/dispatched/receipted at all yet.
    assert :error = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    assert [] =
             Item
             |> Ash.read!(domain: ItemDomain)
             |> Enum.filter(&(&1.label == label))
  end

  test "a real CommandWorker.perform/1, run via Oban.Testing.perform_job/2, reconstructs the command, performs a real Ash.create, and commits a real Receipt",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)
    assert receipt.status == :completed
    assert receipt.consequence == :change
    assert receipt.replayed? == false
    assert receipt.capability_id == @capability_id

    created =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{label: ^label}] = created
  end

  test "running CommandWorker.perform/1 twice for the same command_id replays instead of double-executing",
       %{suffix: suffix, label: label} do
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id) |> dequeue!()

    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)
    assert {:ok, first_receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    items_after_first =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{id: created_id}] = items_after_first

    # Oban's own at-least-once delivery semantics: the same real DB job row
    # is dequeued and attempted a second time (a real Ecto update bumping
    # `attempt`/`attempted_at`, exactly what a live Oban queue producer's
    # own dequeue SQL does on redelivery -- not a fabricated retry).
    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)
    assert {:ok, second_receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    # Same stored receipt identity both times -- the store never
    # re-committed a second receipt for this command_id.
    assert second_receipt.receipt_id == first_receipt.receipt_id
    assert second_receipt.fingerprint == first_receipt.fingerprint

    # Real final state, not just receipt bookkeeping: no second Ash.create
    # happened -- still exactly one real Item row for this label, and it
    # is the same record.
    items_after_second =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{id: ^created_id}] = items_after_second
  end

  test "a command carrying a real semantic_subject round-trips its fingerprint through real Oban delivery + real CommandWorker reconstruction",
       %{suffix: suffix, label: label} do
    command = build_command_with_semantic_subject("cmd-sem-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: job_id}} = enqueue(command)

    job = AshA2A.Test.Repo.get!(Oban.Job, job_id)

    # The real, DB-persisted job args carry the semantic_subject fields --
    # confirmed directly against the real oban_jobs row, not by trusting
    # payload/1's return value alone.
    assert job.args["semantic_subject_graph_digest"] == command.semantic_subject.graph_digest

    assert job.args["semantic_subject_projection_digest"] ==
             command.semantic_subject.projection_digest

    assert job.args["semantic_subject_manufacturer_digest"] ==
             command.semantic_subject.manufacturer_digest

    assert job.args["semantic_subject_ephemeral"] == command.semantic_subject.ephemeral?

    job = dequeue!(job)
    assert :ok = Oban.Testing.perform_job(job, repo: AshA2A.Test.Repo)

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)

    # The real regression this closes: AshA2A.Test.Support.CommandWorker's
    # real reconstruct_command/1, run through a real Oban job round-trip,
    # must recompute the SAME fingerprint the original command carried --
    # exactly the discriminator AshA2A.ReceiptStore's claim logic uses to
    # tell a legitimate replay apart from a :command_conflict.
    assert receipt.fingerprint == command.fingerprint

    created =
      Item
      |> Ash.read!(domain: ItemDomain)
      |> Enum.filter(&(&1.label == label))

    assert [%Item{label: ^label}] = created
  end

  # Same shape as build_command/2, plus a real, validated
  # AshA2A.SemanticSubject -- exercising the documented WF-5 continuation
  # flow this fix targets, where a command carries exact
  # semantic/manufacture identity through delivery.
  defp build_command_with_semantic_subject(command_id, label) do
    principal = Identity.principal("subject-#{command_id}")
    # Real grant, not a hand-built struct -- CommandWorker.perform/1 now
    # re-verifies live broker standing (see command_worker.ex's moduledoc,
    # "Live authority re-verification"), so the authority must really be
    # granted through the configured broker, not merely constructed.
    {:ok, authority} = Grant.grant(principal, @capability_id)

    {:ok, semantic_subject} =
      SemanticSubject.new(
        graph_digest: "sha256:" <> String.duplicate("1", 64),
        projection_digest: "sha256:" <> String.duplicate("2", 64),
        manufacturer_digest: "sha256:" <> String.duplicate("3", 64),
        ephemeral?: false
      )

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      semantic_subject: semantic_subject,
      input: %{"label" => label}
    )
  end

  # Real dequeue-claim step, replicating what a live Oban queue producer's
  # own dequeue SQL does when it claims an `available` job for execution
  # (`attempted_at: now`, `attempt: attempt + 1`) -- `deps/oban/lib/oban/
  # queues/executor.ex:198-200`'s `record_finished/1` requires a non-nil
  # `job.attempted_at` (it computes `queue_time` as `DateTime.diff(job.
  # attempted_at, job.scheduled_at, ...)`), which a job fetched straight off
  # `oban_jobs` never has -- real Oban always sets it via this same dequeue
  # step, which this test intentionally bypasses (no active queue: `queues:
  # []`) so it can drive `Oban.Testing.perform_job/2` directly. A real Ecto
  # update against the real row, not an in-memory-only patch, so `oban_jobs`
  # itself reflects the real attempt count/timestamp exactly as it would
  # under a live queue.
  defp dequeue!(%Oban.Job{} = job) do
    job
    |> Ecto.Changeset.change(attempted_at: DateTime.utc_now(), attempt: job.attempt + 1)
    |> AshA2A.Test.Repo.update!()
  end

  # `AshA2A.Delivery.Oban.enqueue/3` calls `Oban.Job.new/2` directly (not
  # `CommandWorker.new/2`), so it does not itself merge in the worker's own
  # `use Oban.Worker, queue: :commands` compile-time default -- a caller
  # supplies its intended queue explicitly via `job_opts:`, exactly as a
  # real host integration would.
  defp enqueue(command) do
    Delivery.Oban.enqueue(CommandWorker, command,
      name: @oban_name,
      job_opts: [queue: :commands]
    )
  end

  # -- Real command construction, mirroring
  # test/ash_a2a/command_bus_test.exs's own
  # "matching authority admits a real create and commits its receipt"
  # pattern -- same capability id form, same Authority/Command shape.
  defp build_command(command_id, label) do
    principal = Identity.principal("subject-#{command_id}")
    # Real grant, not a hand-built struct -- see build_command_with_semantic_
    # subject/2's comment above for why.
    {:ok, authority} = Grant.grant(principal, @capability_id)

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      input: %{label: label}
    )
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
        repo_config

      {:error, reason} ->
        raise """
        Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
        for AshA2A.Test.Repo (test/ash_a2a/oban_delivery_qualification_test.exs).
        Reason: #{inspect(reason)}

        This test needs a real, dedicated local Postgres instance to create
        and query Oban's real `oban_jobs` table against (GAP D real Oban
        integration -- Chicago-style discipline: no mocked queue, no
        stubbed DB). This release cycle expects one already running at
        that host/port/db (see config/test.exs for the exact connection
        opts this test reads). Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: mix test test/ash_a2a/oban_delivery_qualification_test.exs
        """
    end
  end
end
