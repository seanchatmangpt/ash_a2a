# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.IdentityGuard do
  @moduledoc false

  def admit(%{
        request_id: "sha256:" <> r,
        effect_id: "sha256:" <> e,
        subject_digest: "sha256:" <> s
      })
      when byte_size(r) == 64 and byte_size(e) == 64 and byte_size(s) == 64,
      do: :ok

  def admit(_), do: {:error, :prepared_record_identity_mismatch}
end
