# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.ExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ExactSubject

  test "requires exact repo, source SHA, semantic subject and candidate digest" do
    candidate = %{
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("a", 40),
      semantic_subject_digest: "sha256:" <> String.duplicate("b", 64),
      candidate_digest: "sha256:" <> String.duplicate("c", 64)
    }

    assert {:ok, exact} = ExactSubject.admit(candidate)
    assert exact.repository == "seanchatmangpt/beam4pm"

    assert {:error, {:refused_gall, :exact_subject, :invalid_or_inexact_subject}} =
             ExactSubject.admit(Map.put(candidate, :producer_sha, "head"))
  end
end
