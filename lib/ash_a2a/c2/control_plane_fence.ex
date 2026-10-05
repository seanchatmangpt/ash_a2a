# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ControlPlaneFence do
  @forbidden [:secret, :private_key, :access_token, :password, :credential]
  def clean?(m) when is_map(m),
    do:
      Enum.all?(Map.keys(m), fn k ->
        k not in @forbidden and to_string(k) not in Enum.map(@forbidden, &to_string/1)
      end)
end
