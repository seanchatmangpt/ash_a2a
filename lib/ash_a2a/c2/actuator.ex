# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.Actuator do
  def execute(effect, cert, ctx, store, effector) do
    with :ok <- AshA2A.C2.CompleteMediation.admit(effect, cert, ctx),
         :ok <- store.claim(effect.digest, cert.generation),
         {:ok, r} <- effector.perform(effect),
         :ok <- store.complete(effect.digest, r) do
      {:ok, r}
    end
  end
end
