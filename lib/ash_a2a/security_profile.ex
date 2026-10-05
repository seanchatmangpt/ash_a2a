# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityProfile do
  @moduledoc """
  RFC-SA2A-007 security profile: `:strict` (default), `:dev_bypass`
  (opt-in, compiled out of prod) or `:legacy_compat` (explicit).

  Selection comes only from build configuration,
  `config :ash_a2a, :security_profile, profile`, read with
  `Application.compile_env/3`. There is no call option, metadata key, request
  field or runtime env lookup: `current/0` takes no arguments and is a
  constant of the compiled module. A release whose runtime config disagrees
  with the compiled value fails Elixir's own compile-env boot validation, so
  `config/runtime.exs` may restate the profile but cannot change it.

  See `AshA2A.SecurityProfile.Template` for the compile-time rules and
  `AshA2A.SecurityProfile.Boot` for what each profile enforces at boot.
  """

  use AshA2A.SecurityProfile.Template,
    env: Mix.env(),
    requested: Application.compile_env(:ash_a2a, :security_profile, :strict)
end
