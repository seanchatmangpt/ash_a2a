# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.MigrationTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Migration

  test "migration preserves exact producer and candidate identity" do
    candidate = %{
      candidate_digest: "sha256:" <> String.duplicate("a", 64),
      producer_repository: "seanchatmangpt/beam4pm",
      producer_sha: String.duplicate("b", 40)
    }

    assert {:ok, migrated} = Migration.to_v1(candidate)
    assert migrated["candidate_digest"] == candidate.candidate_digest
    assert migrated["producer_sha"] == candidate.producer_sha
    assert migrated["authority"] == "NONE"
    assert migrated["standing"] == "CANDIDATE"
  end
end
