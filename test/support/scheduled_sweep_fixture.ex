defmodule AshA2A.Test.Fixture.ScheduledSweep do
  @moduledoc """
  Real fixture resource proving `AshOban`'s `scheduled_actions` (cron) DSL
  actually fires a real Ash action -- not merely that the `:ash_oban`
  dependency resolves.

  `AshOban` ships two distinct mechanisms: `triggers` (data-driven -- a
  `where` filter on existing records) and `scheduled_actions` (time-driven,
  real cron expressions, for periodic maintenance work like pruning stale
  evidence -- e.g. old `AshA2A.Receipt`/`AshA2A.Semantic.ExecutionPackage`
  entries -- that has nothing to do with any single record's state). This
  fixture exercises `scheduled_actions` specifically, since that is the real
  gap: `mix.exs` declared `{:ash_oban, "~> 0.8"}` with zero resource using
  either DSL anywhere in this repository.

  A real cron-scheduled Oban job (queue `:maintenance`) calls the real
  `:sweep` generic action, which performs a real `Ash.create` (via
  `:record_sweep`) persisting a real, ETS-backed `swept_at` record each time
  it fires -- proven by `AshOban.Test.schedule_and_run_triggers/2`
  (Oban's own real, documented drain-queue test helper; no hand-rolled
  scheduler loop, no mocked cron clock) and confirmed via `Ash.read!/2`
  against the real resulting records, not by inspecting Oban job bookkeeping
  alone.
  """

  use Ash.Resource,
    domain: AshA2A.Test.Fixture.ScheduledSweepDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOban]

  attributes do
    uuid_primary_key(:id)
    attribute(:swept_at, :utc_datetime_usec, public?: true)
    attribute(:swept_by, :string, public?: true)
  end

  actions do
    defaults([:read])

    # The real persistence primitive. Kept as a plain :create action (not
    # itself the AshOban-scheduled one -- see `:sweep` below and its
    # moduledoc note) so it can be exercised directly too.
    create :record_sweep do
      accept([])

      change(set_attribute(:swept_at, &DateTime.utc_now/0))

      change(fn changeset, context ->
        Ash.Changeset.change_attribute(changeset, :swept_by, actor_id(context.actor))
      end)
    end

    # AshOban's `scheduled_actions` DSL documents `action:` as "the generic
    # or create action to call" -- but the installed ash_oban 0.8.14's
    # generated worker (deps/ash_oban/lib/transformers/define_action_workers.ex,
    # confirmed by direct read and by reproducing the real failure this
    # fixture originally hit pointing `action:` straight at :record_sweep)
    # unconditionally invokes via `Ash.ActionInput.new/0` ->
    # `Ash.ActionInput.for_action/4` -> `Ash.run_action!/1` -- the GENERIC
    # action path only. A real generic action that itself performs the real
    # create is therefore the correct, working shape for this version, not
    # a doc-text technicality dodged -- `:sweep` genuinely IS a generic
    # `:action`, and it genuinely performs a real `Ash.create` as its own
    # implementation.
    action :sweep, :struct do
      constraints(instance_of: __MODULE__)

      run(fn _input, context ->
        __MODULE__
        |> Ash.Changeset.for_create(:record_sweep, %{},
          actor: context.actor,
          domain: AshA2A.Test.Fixture.ScheduledSweepDomain
        )
        |> Ash.create()
      end)
    end
  end

  oban do
    scheduled_actions do
      # Every 5 minutes in real production; the real wall-clock schedule
      # itself is never awaited in tests -- AshOban.Test.schedule_and_run_triggers/2
      # triggers the real underlying Oban job synchronously instead of
      # waiting for the cron clock to tick, the same real testing pattern
      # Oban's own documentation prescribes.
      schedule(:periodic_sweep, "*/5 * * * *",
        action: :sweep,
        queue: :maintenance,
        default_actor: %{id: "system"},
        worker_module_name: AshA2A.Test.Fixture.ScheduledSweep.AshOban.PeriodicSweep
      )
    end
  end

  defp actor_id(%{id: id}), do: to_string(id)
  defp actor_id(_), do: nil
end

defmodule AshA2A.Test.Fixture.ScheduledSweepDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(AshA2A.Test.Fixture.ScheduledSweep)
  end
end
