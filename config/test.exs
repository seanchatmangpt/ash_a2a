import Config

config :ash_a2a, ash_domains: [AshA2A.Test.Fixture.Domain]

# Real Phoenix.Presence host config for
# AshA2A.RuntimeProvidersIntegrationTest -- exercises
# AshA2A.Topology.Presence against a real Presence module backed by a real
# Phoenix.PubSub.
config :ash_a2a, AshA2A.Test.PresenceFixture, pubsub_server: AshA2A.Test.PubSubFixture

# req_llm's default Finch pool (stream_pool_size: 1, stream_pool_count: 16)
# genuinely bottlenecked test/ash_a2a_zai_concurrency_ocel_test.exs's real
# 50-way concurrent Z.AI dispatch -- a real NimblePool checkout timeout was
# hit and diagnosed, not guessed in advance. Raised so this repo's test
# suite can actually validate real HTTP-level concurrency at the scale it
# claims, not just claim it via `max_concurrency:` alone.
config :req_llm, stream_pool_size: 60, stream_pool_count: 4

# Role-based LLM provider resolution (AshA2A.LLMProfiles) -- the only place
# a real provider/model string is named. Ash actions reference the role
# (:semantic_reasoner), never this config's contents directly.
config :ash_a2a, :llm_profiles,
  semantic_reasoner: [
    provider: :zai_coder,
    model: "glm-5.3-flash",
    max_tokens: 4096
  ]

# GAP D -- real Oban delivery qualification
# (test/ash_a2a/oban_delivery_qualification_test.exs). AshA2A.Test.Repo is
# the real Ecto.Repo AshA2A.Delivery.Oban.enqueue/3 and a real Oban.Worker
# are exercised against (real oban_jobs table via Oban.Migrations.up/0,
# real Oban.insert/2, real Oban.Testing.perform_job/2) -- pointed at this
# release cycle's dedicated, already-running local Postgres instance. Not
# started or managed by this test suite itself; the test's own setup_all
# checks reachability for real before starting the repo.
config :ash_a2a, ecto_repos: [AshA2A.Test.Repo]

config :ash_a2a, AshA2A.Test.Repo,
  hostname: "localhost",
  port: 55432,
  username: "postgres",
  password: "postgres",
  database: "ash_a2a_test",
  pool_size: 4
