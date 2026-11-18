# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.VocabularyPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.VocabularyPolicy

  test "admits explicit public vocabulary and refuses private namespaces" do
    candidate = %{vocabulary: "https://w3id.org/ocel"}
    assert {:ok, ^candidate} = VocabularyPolicy.admit(candidate, ["https://w3id.org/ocel"])

    assert {:error, {:refused_gall, :vocabulary_policy, :private_vocabulary}} =
             VocabularyPolicy.admit(%{vocabulary: "private:internal"}, ["private:internal"])
  end
end
