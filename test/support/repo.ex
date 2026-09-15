defmodule AshA2A.Test.Repo do
  @moduledoc """
  Real `Ecto.Repo` for GAP D's real-Oban-integration qualification
  (`test/ash_a2a/oban_delivery_qualification_test.exs`) -- the actual
  PostgreSQL connection `AshA2A.Delivery.Oban.enqueue/3` and a real
  `Oban.Worker` are exercised against via a real `oban_jobs` table, per
  this workspace's Chicago-style testing discipline (real collaborators,
  state-based assertions -- no mocked queue, no stubbed job execution).

  Connection opts are read from `config :ash_a2a, AshA2A.Test.Repo, ...`
  (`config/test.exs`), pointed at this release cycle's dedicated,
  already-running local Postgres instance
  (`host=localhost port=55432 user=postgres password=postgres
  database=ash_a2a_test`) -- not started or managed by this repo's test
  suite itself.
  """

  use Ecto.Repo,
    otp_app: :ash_a2a,
    adapter: Ecto.Adapters.Postgres
end
