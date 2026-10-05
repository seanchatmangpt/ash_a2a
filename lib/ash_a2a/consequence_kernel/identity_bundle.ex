# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.IdentityBundle do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.{EffectIdentity, ExactSubject, RequestIdentity}

  def build(request, effect, subject) do
    with {:ok, r} <- RequestIdentity.derive(request),
         {:ok, e} <- EffectIdentity.derive(r, effect),
         {:ok, s} <- ExactSubject.bind(subject) do
      {:ok, %{request_id: r, effect_id: e, subject_digest: s}}
    end
  end
end
