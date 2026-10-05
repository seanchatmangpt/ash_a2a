import Config

# Required by Ash >= 3.34 for any resource with a `:string` attribute.
config :ash, :default_string_length_count, :codepoints

# Compile-time security profile of the ash_a2a build this demo compiles
# against. `:legacy_compat` runs the same boot preflight as `:strict` but
# logs its findings as warnings instead of refusing to boot -- the right
# profile for a demo whose receipt store is deliberately in-memory and whose
# authority broker is the reference InMemory broker.
config :ash_a2a, :security_profile, :legacy_compat

config :ash_a2a, :env, :dev

# Fail-closed authority: a `:change` consequence is admitted only against a
# real standing grant from this broker (started by A2aDemo.Application).
config :ash_a2a, :authority_broker, AshA2A.Authority.Broker.InMemory
