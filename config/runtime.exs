import Config

# Prod-like runtime template (RFC-SA2A-007 :strict). It applies ONLY under
# config_env() in [:prod, :conformance], so dev and test are untouched. Copy
# the block into a host application's config/runtime.exs and supply the
# environment variables. `:conformance` is the build environment for
# `MIX_ENV=conformance mix ash_a2a.verify_conformance --profile c1` (see
# docs/reference/conformance-profiles.md): same :strict profile and same
# durable stores as prod, selected only by the build environment.
#
# Required environment (no defaults; boot/verification refuses without them):
#   ASH_A2A_DATA_DIR        durable volume root (never under tmp)
#   ASH_A2A_OUTBOX_KEY_B64  base64 HMAC key, >= 32 bytes decoded
#
# The profile itself is a build-time constant read through
# Application.compile_env/3; restating it here is allowed but a value that
# differs from the compiled one fails release boot (compile-env validation).
if config_env() in [:prod, :conformance] do
  config :ash_a2a, :security_profile, :strict

  data_dir = System.fetch_env!("ASH_A2A_DATA_DIR")

  outbox_key = Base.decode64!(System.fetch_env!("ASH_A2A_OUTBOX_KEY_B64"))

  if byte_size(outbox_key) < 32 do
    raise "ASH_A2A_OUTBOX_KEY_B64 must decode to at least 32 bytes (HMAC key for the " <>
            "receipt outbox and the prepared journal)"
  end

  # Keyed receipt outbox on a durable volume (never under tmp).
  config :ash_a2a,
    receipt_outbox_key: outbox_key,
    receipt_outbox_dir: Path.join(data_dir, "receipt_outbox"),
    # Keyed, sequence-numbered prepared journal (same key as the outbox).
    prepared_journal_dir: Path.join(data_dir, "prepared_journal"),
    # Durable compare-and-set claim store (fence atomic with the write).
    claim_store: AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile,
    claim_store_dir: Path.join(data_dir, "claims"),
    receipt_store: AshA2A.ReceiptStore.Ekv,
    receipt_store_ekv_opts: [data_dir: Path.join(data_dir, "receipts"), cluster_size: 3],
    authority_broker: {AshA2A.Authority.Broker.Ekv, data_dir: Path.join(data_dir, "authority")},
    authority_policy: :broker,
    capability_release_mode: :strict,
    kill_switch_class: System.get_env("ASH_A2A_KILL_SWITCH_CLASS", "ash_a2a"),
    kill_switch_path: Path.join(data_dir, "kill_switch.dets"),
    production: true
end
