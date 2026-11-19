# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.Closure.CompatibilityTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.Compatibility

  test "only closure-v1 representation is admitted" do
    artifact = %{"schema_version" => "ash_a2a.gall.closure/v1"}
    assert {:ok, ^artifact} = Compatibility.admit(artifact)

    assert {:error, {:refused_gall, :compatibility, {:unsupported_version, "v0"}}} =
             Compatibility.admit(%{"schema_version" => "v0"})
  end
end
