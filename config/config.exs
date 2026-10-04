import Config

config :ash, default_string_length_count: :codepoints

config :ash_a2a, semantic_engine: AshA2A.Semantic.Engine.AshGraphLaw

config :ash_graphlaw, start_pool: true, pool: [size: 2, timeout_ms: 5_000]

# RFC-SA2A-007 security profile (build-time only; default :strict).
# Read via Application.compile_env/3 in AshA2A.SecurityProfile. Applies to
# this repository's own builds; a host application chooses its own profile in
# its own config. The test suite runs under :dev_bypass so the existing
# fixtures (in-memory broker/store, no outbox key) boot; the profile courts
# under test/ash_a2a/security_profile compile :strict and :prod fixtures
# themselves.
case config_env() do
  :test -> config :ash_a2a, :security_profile, :dev_bypass
  :dev -> import_config "dev.exs"
  :prod -> import_config "prod.exs"
  :conformance -> import_config "conformance.exs"
  _ -> :ok
end

if config_env() == :test do
  import_config "test.exs"
end
