import Config

# Build environment for the strict conformance run
# (`MIX_ENV=conformance mix ash_a2a.verify_conformance --profile c1`).
# The profile is a build constant chosen HERE, by the build environment only:
# never by task options, request data or app env at call time. Durable stores,
# the HMAC key and the data dir come from config/runtime.exs (same block as
# :prod). See docs/reference/conformance-profiles.md.
config :ash_a2a, :security_profile, :strict
