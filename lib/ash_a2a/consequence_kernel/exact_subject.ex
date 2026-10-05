# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.ExactSubject do
  @moduledoc false
  alias AshA2A.Identity.Canonical.Migration

  @doc "Canonical digest of `subject` under the subject schema tag."
  def bind(subject), do: Migration.tagged_digest("sa2a.subject.v1", subject)

  @doc """
  Drift check: the subject presented at a later transition must be exactly the one
  bound earlier. A projection, transform or substitution that changes the subject is
  refused with `:prepared_record_identity_mismatch`; it never passes silently.
  """
  def bind(expected, actual) when expected == actual, do: :ok
  def bind(_expected, _actual), do: {:error, :prepared_record_identity_mismatch}

  def admit(subject, expected), do: Migration.verify("sa2a.subject.v1", subject, expected)
end
