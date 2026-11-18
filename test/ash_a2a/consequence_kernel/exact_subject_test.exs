# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ExactSubjectTest do
  use ExUnit.Case, async: true

  test "refuses drift" do
    assert :ok = AshA2A.ConsequenceKernel.ExactSubject.bind("a", "a")

    assert {:error, :prepared_record_identity_mismatch} =
             AshA2A.ConsequenceKernel.ExactSubject.bind("a", "b")
  end
end
