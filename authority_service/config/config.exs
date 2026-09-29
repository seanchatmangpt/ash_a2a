import Config

# No static secrets here. Runtime settings come from config/runtime.exs (files, never env
# for key material).
config :authority_service, :start_service, config_env() != :test
