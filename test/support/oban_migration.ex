defmodule AshA2A.Test.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Real `Ecto.Migration` wrapping Oban's own real `Oban.Migrations.up/1` and
  `Oban.Migrations.down/1` helpers (`deps/oban/lib/oban/migration.ex`) --
  creates the real `oban_jobs` table (plus its supporting `oban_job_state`
  enum type and notify trigger/function) that
  `test/ash_a2a/oban_delivery_qualification_test.exs` inserts into via
  `AshA2A.Delivery.Oban.enqueue/3` and queries directly via
  `AshA2A.Test.Repo`.

  Applied for real in that test's `setup_all` via `Ecto.Migrator.up/4`
  against the real, already-running local Postgres instance this release
  cycle provides -- never assumed already present, and idempotent (`Ecto.
  Migrator.up/4` records the applied version in `schema_migrations` and
  returns `:already_up` on a subsequent run instead of re-executing).
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
