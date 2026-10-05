# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.AuthorityRevalidation do
  def check(authority, prepared, principal) do
    authority.revalidate(
      principal,
      prepared.instance.subject_digest,
      prepared.consequence_class,
      prepared.authority_epoch
    )
  end
end
