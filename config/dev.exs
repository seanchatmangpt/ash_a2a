import Config

# RFC-SA2A-007: the default profile is :strict. This repository's own dev
# environment opts into :dev_bypass so `iex -S mix` boots without a keyed
# outbox, durable stores or a broker. dev_bypass prints a loud boot banner,
# emits [:ash_a2a, :security_profile, :dev_bypass] and stamps every receipt.
# It is compiled out of :prod builds (requesting it there is a CompileError).
config :ash_a2a, :security_profile, :dev_bypass
