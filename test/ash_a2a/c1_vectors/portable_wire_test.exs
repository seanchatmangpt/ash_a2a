# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1PortableWireTest do
  use ExUnit.Case, async: true

  test "wire identity is sha256 JCS domain" do
    assert {:ok, d} = AshA2A.ConsequenceKernel.Wire.digest(%{"x" => 1})
    assert byte_size(d) == 71
  end
end
