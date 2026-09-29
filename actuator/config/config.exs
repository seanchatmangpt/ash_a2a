import Config

# The server (UDS/mTLS listeners + Store) is started by Actuator.Application only when
# true; tests start their own Store/listeners against a temporary state directory.
config :actuator, start_server: true

import_config "#{config_env()}.exs"
