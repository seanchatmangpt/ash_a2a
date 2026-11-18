# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Replan.PortableSchemaTest do
  use ExUnit.Case, async: true

  alias AshA2A.Replan.PortableSchema

  test "portable schema has stable content identity" do
    decoded = PortableSchema.decode!()
    assert decoded["$id"] == "https://chatmangpt.com/sa2a/replan-envelope/v1"
    assert PortableSchema.digest() =~ ~r/^sha256:[0-9a-f]{64}$/
  end
end
