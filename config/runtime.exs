import Config

# Prod-like runtime template (RFC-SA2A-007 :strict). It applies ONLY under
# config_env() == :prod, so dev and test are untouched. Copy the block into a
# host application's config/runtime.exs and supply the environment variables.
#
# The profile itself is a build-time constant read through
# Application.compile_env/3; restating it here is allowed but a value that
# differs from the compiled one fails release boot (compile-env validation).
if config_env() == :prod do
  config :ash_a2a, :security_profile, :strict

  data_dir = System.fetch_env!("ASH_A2A_DATA_DIR")

  # Keyed receipt outbox on a durable volume (never under tmp).
  config :ash_a2a,
    receipt_outbox_key: Base.decode64!(System.fetch_env!("ASH_A2A_OUTBOX_KEY_B64")),
    receipt_outbox_dir: Path.join(data_dir, "receipt_outbox"),
    receipt_store: AshA2A.ReceiptStore.Ekv,
    receipt_store_ekv_opts: [data_dir: Path.join(data_dir, "receipts"), cluster_size: 3],
    authority_broker: {AshA2A.Authority.Broker.Ekv, data_dir: Path.join(data_dir, "authority")},
    authority_policy: :broker,
    capability_release_mode: :strict,
    kill_switch_class: System.get_env("ASH_A2A_KILL_SWITCH_CLASS", "ash_a2a"),
    kill_switch_path: Path.join(data_dir, "kill_switch.dets"),
    production: true
end
