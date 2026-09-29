defmodule AshA2A.ConsequenceKernel.ExactSubject do
  @moduledoc false
  alias AshA2A.Identity.Canonical.Migration
  def bind(subject), do: Migration.tagged_digest("sa2a.subject.v1",subject)
  def admit(subject,expected), do: Migration.verify("sa2a.subject.v1",subject,expected)
end
