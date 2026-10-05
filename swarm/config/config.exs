import Config

config :ash, default_string_length_count: :codepoints

# ash_a2a's boot-time durability warning keys off `:env` (default :prod). Tell
# it the real Mix env so dev/test runs of this host do not claim to be prod;
# the prod release gets :prod plus the fail-closed durable config in
# config/runtime.exs.
config :ash_a2a, env: config_env()

# RFC-SA2A-007 security profile (build-time only; default :strict). ash_a2a
# is a path dependency here, so it compiles with Mix.env() == :prod and the
# :dev_bypass profile is compiled out for this host -- the only host-facing
# non-strict option is :legacy_compat, which logs the strict preflight
# findings as warnings instead of refusing dev/test boot. The :prod release
# stays :strict and fully durable via config/runtime.exs.
if config_env() in [:dev, :test] do
  config :ash_a2a, :security_profile, :legacy_compat
end
