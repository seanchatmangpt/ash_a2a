import Config

config :ultracode, Ultracode.Repo,
  database: "ultracode_test",
  pool: Ecto.Adapters.SQL.Sandbox

# Real Oban.Testing manual mode -- jobs are inserted for real (real rows in
# a real oban_jobs table) but not auto-executed by a running queue producer;
# tests that need a job to run call Oban.Testing.perform_job/2 for real.
config :ultracode, Oban, testing: :manual

config :logger, level: :warning
