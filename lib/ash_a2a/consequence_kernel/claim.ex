# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Claim do
  def request(store, request_id, owner), do: store.claim_request(request_id, owner)
  def effect(store, effect_id, owner), do: store.claim_effect(effect_id, owner)
  def release_effect(store, effect_id, owner), do: store.release_effect(effect_id, owner)
end
