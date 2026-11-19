# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Gall.FieldsGetTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Fields

  test "present nil/false atom values are not skipped for the string key" do
    assert Fields.get(%{:a => false, "a" => true}, :a) == false
    assert Fields.get(%{:a => nil, "a" => 1}, :a) == nil
    assert Fields.fetch(%{:a => false, "a" => true}, :a) == {:ok, false}
  end

  test "falls back to string key and reports absence" do
    assert Fields.get(%{"a" => 2}, :a) == 2
    assert Fields.fetch(%{}, :a) == :error
    assert Fields.get(%{}, :a) == nil
  end
end
