# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.PreparedEffectPortableDigestTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.PreparedEffect
  alias AshA2A.Identity.Canonical

  test "digest is JCS SHA-256 over the portable view" do
    effect =
      PreparedEffect.new(
        "principal:alice",
        :payments,
        %{"kind" => "order", "id" => 42},
        %{amount: 100, currency: "USD"}
      )

    assert {:ok, view} = PreparedEffect.portable_view(effect)
    assert {:ok, expected} = Canonical.digest(view)
    assert effect.digest == expected
    refute String.contains?(effect.digest, "term")
  end

  test "map key ordering cannot change effect identity" do
    a = PreparedEffect.new("p", :cap, %{"b" => 2, "a" => 1}, %{y: 2, x: 1})
    b = PreparedEffect.new("p", :cap, %{"a" => 1, "b" => 2}, %{x: 1, y: 2})
    assert a.digest == b.digest
  end

  test "non portable values are refused by build/4" do
    assert {:error, :canonical_type_forbidden} =
             PreparedEffect.build("p", :cap, "s", {:tuple, :not, :json})
  end
end
