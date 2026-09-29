import Config

# RFC-SA2A-007: :prod builds are :strict. This file states it explicitly;
# requesting :dev_bypass here would be a CompileError by construction.
# Host applications set the same key in their own config/prod.exs; this
# repository's config is not loaded when ash_a2a is a dependency.
config :ash_a2a, :security_profile, :strict
