# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

import Config

# RFC-SA2A-007: :prod builds are :strict. This file states it explicitly;
# requesting :dev_bypass here would be a CompileError by construction.
# Host applications set the same key in their own config/prod.exs; this
# repository's config is not loaded when ash_a2a is a dependency.
config :ash_a2a, :security_profile, :strict

# Prod transport hardening (sobelow Config.HTTPS). ash_a2a ships no endpoint of
# its own -- hosts mount `AshA2A.Transport.Plug` inside their own endpoint and
# own the TLS termination in front of it. This block states the prod posture
# hosts adopting this repository's config should apply to the mounted
# transport, and `AshA2A.Transport.Plug` honours a `:force_ssl` init option for
# direct mounts (requests arriving over plaintext behind a proxy that sets
# `x-forwarded-proto: http` are refused with `400`; HSTS is served on every
# response). Cookies issued by a host session layer must additionally be set
# `secure`/http-only -- that is host-owned, not transport-owned.
config :ash_a2a,
  force_ssl: [rewrite_on: [:x_forwarded_proto], hsts: true, hsts_include_subdomains: true]
