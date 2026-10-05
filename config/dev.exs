# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

import Config

# RFC-SA2A-007: the default profile is :strict. This repository's own dev
# environment opts into :dev_bypass so `iex -S mix` boots without a keyed
# outbox, durable stores or a broker. dev_bypass prints a loud boot banner,
# emits [:ash_a2a, :security_profile, :dev_bypass] and stamps every receipt.
# It is compiled out of :prod builds (requesting it there is a CompileError).
config :ash_a2a, :security_profile, :dev_bypass

# RFC-SA2A-002 §34 gate 3 (CHI-REAL-008): the dev configuration must identify
# every §34 role. Wire the same real, fail-closed authority boundary prod and
# conformance use (`config/runtime.exs`): the EKV-backed broker over a real
# on-disk data dir. `AshA2A.Application` starts the matching named EKV child
# from this exact config (`authority_broker_children/0`), and the ungranted
# probe through `AshA2A.Authority.Grant.authorize/3` is refused by the real
# boundary -- no broker, not a stub.
config :ash_a2a,
  authority_broker:
    {AshA2A.Authority.Broker.Ekv,
     data_dir: Path.expand("tmp/ash_a2a/dev_authority_ekv", File.cwd!())},
  authority_policy: :broker
