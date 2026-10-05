# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.RequestIdentity do
  @moduledoc false
  def derive(request),
    do: AshA2A.Identity.Canonical.Migration.tagged_digest("sa2a.request.v1", request)
end
