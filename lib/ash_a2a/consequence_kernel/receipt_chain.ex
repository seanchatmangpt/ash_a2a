# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.ReceiptChain do
  def next(previous_digest, receipt) do
    AshA2A.Identity.Canonical.digest(%{"previous" => previous_digest, "receipt" => receipt})
  end
end
