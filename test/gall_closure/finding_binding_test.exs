# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GallClosure.FindingBindingTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.FindingBinding

  test "bounded admission",
    do: assert(match?({:ok, _}, FindingBinding.admit(%{finding_id: "witness"})))

  test "typed refusal", do: assert(FindingBinding.admit(%{}) == {:error, :missing_finding})
end
