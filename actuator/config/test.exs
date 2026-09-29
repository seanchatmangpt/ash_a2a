import Config

# start_server false: tests drive Store/wire directly. fault_hook true compiles the
# ACTUATOR_TEST_CRASH crash points (compiled OUT of dev/prod) used by the crash court.
config :actuator, start_server: false, fault_hook: true
config :logger, level: :warning
