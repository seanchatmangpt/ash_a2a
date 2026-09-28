import Config

config :ash, default_string_length_count: :codepoints

# ash_a2a's boot-time durability warning keys off `:env` (default :prod). Tell
# it the real Mix env so dev/test runs of this host do not claim to be prod;
# the prod release gets :prod plus the fail-closed durable config in
# config/runtime.exs.
config :ash_a2a, env: config_env()
