defmodule AshA2A.ScheduledSweepQualificationTest do
  @moduledoc """
  `ash_oban` cron-scheduled-actions qualification.

  `mix.exs` has declared `{:ash_oban, "~> 0.8"}` since v26.9.14, but zero
  resource in this repository used it: `grep -rln "AshOban" lib/ test/`
  returned nothing before this file (confirmed directly, not assumed). This
  is the real gap -- the dependency was dead weight, not that AshOban itself
  was unimplementable.

  `AshOban.Test.Fixture.ScheduledSweep` (`test/support/scheduled_sweep_fixture.ex`)
  declares a real `oban do scheduled_actions do schedule ... end end` cron entry.
  This file proves, against a real PostgreSQL-backed `oban_jobs` table and a
  real `Oban` instance (no mocked queue, no stubbed cron clock, per this
  workspace's Chicago-style testing discipline):

    1. The real cron-scheduled Oban job, run via `AshOban.Test.schedule_and_run_triggers/2`
       (Oban's own real, documented drain-queue test helper -- not a hand-rolled
       scheduler loop), really calls the real `:sweep` create action and
       persists a real, ETS-backed record -- confirmed via `Ash.read!/2`
       against the real resulting records, not by inspecting Oban job
       bookkeeping alone.
    2. The `default_actor` configured in the DSL really reaches the action
       (the persisted `swept_by` field), proving AshOban's actor-passing
       path is real, not merely that a job got enqueued.
    3. Running the same scheduler twice enqueues and executes two real,
       independent jobs (unlike `AshA2A.CommandBus`'s own idempotent replay
       semantics -- a cron tick is not a command with a stable identity to
       replay against; each real tick is its own real execution by design).

  Needs a real, reachable PostgreSQL instance for `AshA2A.Test.Repo`
  (`config/test.exs`) -- Oban's own job queue is always Postgres-backed
  regardless of what data layer the scheduled resource itself uses;
  `setup_all` checks that for real and raises with setup instructions
  (matching `test/ash_a2a/oban_delivery_qualification_test.exs`'s own
  convention) rather than crashing opaquely if none is reachable.

  Uses the literal default `Oban` process name (not a custom-named instance,
  unlike `oban_delivery_qualification_test.exs`'s `AshA2A.Test.Oban`):
  `AshOban.schedule/3` calls the bare arity-1 `Oban.insert!/1` internally
  (confirmed by reading `deps/ash_oban/lib/ash_oban.ex` directly, not
  assumed), which always targets the process registered under the literal
  name `Oban` -- a custom name has no effect on where AshOban itself inserts
  the job, only on `AshOban.Test`'s own drain step, so the two must agree.
  Confirmed via grep that no other test file in this suite starts a
  supervised process under that same literal name, so this is safe under
  this repo's serialized `async: false` test execution.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  alias AshA2A.Test.Fixture.ScheduledSweep

  setup_all do
    repo_config = ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    start_supervised!(
      {Oban,
       name: Oban,
       repo: AshA2A.Test.Repo,
       queues: [maintenance: 5],
       plugins: false,
       testing: :manual}
    )

    %{repo_config: repo_config}
  end

  setup do
    on_exit(fn ->
      # Real cleanup so each test's own oban_jobs rows do not leak into the
      # next test in this file.
      AshA2A.Test.Repo.query!("TRUNCATE oban_jobs", [])
    end)

    # The ETS-backed AshA2A.Test.Fixture.ScheduledSweep table is shared
    # across every test in this async: false file (no per-test reset API
    # is used -- matching this repo's own established pattern in
    # oban_delivery_qualification_test.exs of scoping by what a test itself
    # created, rather than assuming a clean slate). Capture the real
    # pre-existing IDs so each test can assert on its own real delta.
    %{before_ids: existing_sweep_ids()}
  end

  test "a real cron-scheduled Oban job really calls the real :sweep action and persists a real record",
       %{before_ids: before_ids} do
    result =
      AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
        scheduled_actions?: true,
        oban: Oban
      )

    assert result.success == 1
    assert result.failure == 0

    assert [%ScheduledSweep{swept_at: %DateTime{}, swept_by: "system"}] =
             new_sweeps(before_ids)
  end

  test "the default_actor configured in the DSL really reaches the action", %{
    before_ids: before_ids
  } do
    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    assert [%ScheduledSweep{swept_by: swept_by}] = new_sweeps(before_ids)
    # The literal default_actor: %{id: "system"} declared in the DSL, not a
    # placeholder -- proving AshOban's actor-passing path is real.
    assert swept_by == "system"
  end

  test "running the scheduler twice really executes two independent real sweeps", %{
    before_ids: before_ids
  } do
    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    AshOban.Test.schedule_and_run_triggers({ScheduledSweep, :periodic_sweep},
      scheduled_actions?: true,
      oban: Oban
    )

    sweeps = new_sweeps(before_ids)
    assert length(sweeps) == 2
    assert Enum.all?(sweeps, &(&1.swept_by == "system"))

    # Two real, distinct records -- not the same row observed twice.
    assert sweeps |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
  end

  defp existing_sweep_ids do
    ScheduledSweep
    |> Ash.read!(domain: AshA2A.Test.Fixture.ScheduledSweepDomain)
    |> MapSet.new(& &1.id)
  end

  defp new_sweeps(before_ids) do
    ScheduledSweep
    |> Ash.read!(domain: AshA2A.Test.Fixture.ScheduledSweepDomain)
    |> Enum.reject(&MapSet.member?(before_ids, &1.id))
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
        for AshA2A.Test.Repo (test/ash_a2a/scheduled_sweep_qualification_test.exs).
        Reason: #{inspect(reason)}

        This test needs a real, dedicated local Postgres instance -- Oban's own
        job queue is always Postgres-backed. This release cycle expects one
        already running at that host/port/db (see config/test.exs for the
        exact connection opts this test reads). Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: mix test test/ash_a2a/scheduled_sweep_qualification_test.exs
        """
    end
  end
end
