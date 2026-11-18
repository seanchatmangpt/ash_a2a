# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SemanticWork.EnvelopeTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Envelope

  test "fetches atom and string keys" do
    assert {:ok, %{a: 1, b: 2}} = Envelope.fetch(%{:a => 1, "b" => 2}, [:a, :b])
  end

  test "nil, empty string and false are missing, first missing key reported" do
    for bad <- [nil, "", false] do
      assert {:error, {:refused_missing_identity, :b}} =
               Envelope.fetch(%{a: 1, b: bad, c: nil}, [:a, :b, :c])
    end

    assert {:error, {:refused_missing_identity, :a}} = Envelope.fetch(%{}, [:a])
  end

  test "zero is present" do
    assert {:ok, %{a: 0}} = Envelope.fetch(%{a: 0}, [:a])
  end
end
