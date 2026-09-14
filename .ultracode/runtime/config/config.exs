import Config

config :ultracode,
  ash_domains: [Ultracode.Domain],
  ecto_repos: [Ultracode.Repo]

config :ultracode, Ultracode.Repo,
  hostname: "localhost",
  port: 55432,
  username: "postgres",
  password: "postgres",
  pool_size: 4

config :ultracode, Oban,
  engine: Oban.Engines.Basic,
  repo: Ultracode.Repo,
  queues: [ultracode: 1],
  plugins: [
    {Oban.Plugins.Cron, crontab: []}
  ]

# Real ZAI glm-5.3-flash provider, independent of ash_a2a's own
# `config :ash_a2a, :llm_profiles` -- this app never compiles against
# ash_a2a, so it configures its own req_llm-based provider entry using the
# same real model this repo already uses elsewhere.
config :ultracode, :zai,
  provider: :zai_coder,
  model: "glm-5.3-flash",
  max_tokens: 4096,
  # req_llm resolves the real key from ZAI_API_KEY at call time; this app
  # never hardcodes or logs the key itself.
  api_key_env: "ZAI_API_KEY"

import_config "#{config_env()}.exs"
