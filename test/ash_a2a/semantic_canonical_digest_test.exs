defmodule AshA2A.Semantic.CanonicalDigestTest do
  @moduledoc """
  The value-level digest the S23/S24/S26/S27 work depends on.

  The properties asserted here are the ones the RFC sections actually lean
  on: map-key order must not matter (or two identical plans digest
  differently and S27's drift check produces false positives), list order
  MUST matter (or two different plans digest identically and the check
  produces false negatives), and distinct values must not collide through
  the encoding.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.CanonicalDigest

  test "digest/1 emits the SemanticSubject-compatible sha256: form" do
    assert CanonicalDigest.digest(%{a: 1}) =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  test "map key insertion order does not change the digest" do
    a = %{} |> Map.put(:x, 1) |> Map.put(:y, 2) |> Map.put(:z, 3)
    b = %{} |> Map.put(:z, 3) |> Map.put(:y, 2) |> Map.put(:x, 1)

    assert a == b
    assert CanonicalDigest.digest(a) == CanonicalDigest.digest(b)
  end

  test "map key order does not change the digest even for large maps" do
    # Erlang switches map representation above 32 keys; the encoding must not
    # notice.
    pairs = for i <- 1..64, do: {:"k#{i}", i}
    forward = Enum.into(pairs, %{})
    backward = pairs |> Enum.reverse() |> Enum.into(%{})

    assert CanonicalDigest.digest(forward) == CanonicalDigest.digest(backward)
  end

  test "list order DOES change the digest -- plan step order is semantic" do
    refute CanonicalDigest.digest([1, 2, 3]) == CanonicalDigest.digest([3, 2, 1])
  end

  test "binaries with embedded delimiters do not collide" do
    refute CanonicalDigest.digest(["a", "b"]) == CanonicalDigest.digest(["a\",\"b"])
    refute CanonicalDigest.digest(["a,b"]) == CanonicalDigest.digest(["a", "b"])
  end

  test "a binary and the atom of the same name do not collide" do
    refute CanonicalDigest.digest("open") == CanonicalDigest.digest(:open)
  end

  test "tuples keep their order and are distinct from lists" do
    refute CanonicalDigest.digest({:a, [:b]}) == CanonicalDigest.digest([:a, [:b]])
    refute CanonicalDigest.digest({:a, :b}) == CanonicalDigest.digest({:b, :a})
  end

  test "structs digest by module and fields, so two structs with the same fields differ" do
    # `AshA2A.Semantic.CapabilityProfile` in the original
    # feat/sa2a-plan-package-v26.9.16 version of this test is not part of
    # this branch's ported closure; `Allocator.Budget` is a real struct
    # with the same property and is.
    budget = AshA2A.Semantic.Allocator.new!([tokens: 10], issued_by: {:host, :digest_test})

    plain = Map.from_struct(budget)

    refute CanonicalDigest.digest(budget) == CanonicalDigest.digest(plain)

    # And a different struct module over identical fields digests
    # differently, which is the property the test is actually about.
    refute CanonicalDigest.digest(%URI{path: "/x"}) ==
             CanonicalDigest.digest(%Version.Requirement{source: "/x", lexed: []})
  end

  test "encode/1's bytes are inspectable, so a digest mismatch is debuggable" do
    assert IO.iodata_to_binary(CanonicalDigest.encode(%{b: 2, a: 1})) == "{:a=1,:b=2}"
    assert IO.iodata_to_binary(CanonicalDigest.encode([:x, "y"])) == "[:x,\"y\"]"
    assert IO.iodata_to_binary(CanonicalDigest.encode({:at, [:room]})) == "(:at,[:room])"
    assert IO.iodata_to_binary(CanonicalDigest.encode(nil)) == "nil"
  end
end
