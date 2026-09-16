defmodule AshA2A.Semantic.CanonicalTermDigestTest do
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

  alias AshA2A.Semantic.CanonicalTermDigest

  test "digest/1 emits the SemanticSubject-compatible sha256: form" do
    assert CanonicalTermDigest.digest(%{a: 1}) =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  test "map key insertion order does not change the digest" do
    a = %{} |> Map.put(:x, 1) |> Map.put(:y, 2) |> Map.put(:z, 3)
    b = %{} |> Map.put(:z, 3) |> Map.put(:y, 2) |> Map.put(:x, 1)

    assert a == b
    assert CanonicalTermDigest.digest(a) == CanonicalTermDigest.digest(b)
  end

  test "map key order does not change the digest even for large maps" do
    # Erlang switches map representation above 32 keys; the encoding must not
    # notice.
    pairs = for i <- 1..64, do: {:"k#{i}", i}
    forward = Enum.into(pairs, %{})
    backward = pairs |> Enum.reverse() |> Enum.into(%{})

    assert CanonicalTermDigest.digest(forward) == CanonicalTermDigest.digest(backward)
  end

  test "list order DOES change the digest -- plan step order is semantic" do
    refute CanonicalTermDigest.digest([1, 2, 3]) == CanonicalTermDigest.digest([3, 2, 1])
  end

  test "binaries with embedded delimiters do not collide" do
    refute CanonicalTermDigest.digest(["a", "b"]) == CanonicalTermDigest.digest(["a\",\"b"])
    refute CanonicalTermDigest.digest(["a,b"]) == CanonicalTermDigest.digest(["a", "b"])
  end

  test "a binary and the atom of the same name do not collide" do
    refute CanonicalTermDigest.digest("open") == CanonicalTermDigest.digest(:open)
  end

  test "tuples keep their order and are distinct from lists" do
    refute CanonicalTermDigest.digest({:a, [:b]}) == CanonicalTermDigest.digest([:a, [:b]])
    refute CanonicalTermDigest.digest({:a, :b}) == CanonicalTermDigest.digest({:b, :a})
  end

  test "structs digest by module and fields, so two structs with the same fields differ" do
    projection = %AshA2A.Semantic.CapabilityProfile{capability_id: "x"}

    plain = %{
      capability_id: "x",
      consequence: nil,
      preconditions: [],
      add_effects: [],
      delete_effects: [],
      authority_requirement: %{}
    }

    refute CanonicalTermDigest.digest(projection) == CanonicalTermDigest.digest(plain)

    # feat/sa2a-bounds-evidence-fixes-v26.9.16 ported this test without
    # `CapabilityProfile` in its closure and substituted
    # `Allocator.Budget`, a real struct with the same property. Both are
    # on main, so both are asserted.
    budget = AshA2A.Semantic.Allocator.new!([tokens: 10], issued_by: {:host, :digest_test})

    refute CanonicalTermDigest.digest(budget) ==
             CanonicalTermDigest.digest(Map.from_struct(budget))

    # And two different struct modules never share a digest.
    refute CanonicalTermDigest.digest(%URI{path: "/x"}) ==
             CanonicalTermDigest.digest(%Version.Requirement{source: "/x", lexed: []})
  end

  test "encode/1's bytes are inspectable, so a digest mismatch is debuggable" do
    assert IO.iodata_to_binary(CanonicalTermDigest.encode(%{b: 2, a: 1})) == "{:a=1,:b=2}"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode([:x, "y"])) == "[:x,\"y\"]"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode({:at, [:room]})) == "(:at,[:room])"
    assert IO.iodata_to_binary(CanonicalTermDigest.encode(nil)) == "nil"
  end
end
