defmodule Sa2aCrypto.SignedMessageTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.{SignedMessage, Fixtures}

  # Frozen vector. The JSON literal is hand-written in RFC 8785 order (sorted keys, no
  # whitespace) and the digest was computed with an independent tool (python hashlib).
  @frozen_json ~s({"alg":"ES256","audience":"actuator:test","effect_digest":"sha256:#{String.duplicate("ab", 32)}","expires":1800000300,"generation":11,"kid":"kid-fixed","nonce":"nonce-0001","not_before":1799999940,"policy_epoch":3,"principal":"agent:alice","revocation_epoch":7,"v":1})
  @frozen_sha256 "5e31ee4bf99a08c6351ac10039a8bfd2e04cba1f55704e3f0e9c911d7ee36493"

  test "frozen JCS + sha256 vector" do
    {:ok, bytes} = SignedMessage.build(Fixtures.base_fields("ES256", "kid-fixed"))
    assert bytes == "SA2A-C2-APPROVAL-v1" <> <<0>> <> @frozen_json
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @frozen_sha256
    assert SignedMessage.digest(bytes) == "sha256:" <> @frozen_sha256
  end

  test "atom-keyed input encodes identically to string-keyed" do
    f = Fixtures.base_fields("ES256", "kid-fixed")
    atoms = Map.new(f, fn {k, v} -> {String.to_atom(k), v} end)
    assert SignedMessage.build(atoms) == SignedMessage.build(f)
  end

  test "principal may be a nested object; key order does not matter" do
    a =
      Fixtures.base_fields("ES256", "k", %{"principal" => %{"b" => 1, "a" => [1, 2, nil, true]}})

    b =
      Fixtures.base_fields("ES256", "k", %{"principal" => %{"a" => [1, 2, nil, true], "b" => 1}})

    assert {:ok, x} = SignedMessage.build(a)
    assert SignedMessage.build(b) == {:ok, x}
    assert x =~ ~s("principal":{"a":[1,2,null,true],"b":1})
  end

  describe "refusals" do
    setup do: {:ok, f: Fixtures.base_fields("ES256", "k")}

    test "floats", %{f: f} do
      assert SignedMessage.build(%{f | "generation" => 1.0}) |> elem(1) == :float_not_allowed

      assert SignedMessage.build(%{f | "principal" => %{"x" => [0.5]}}) ==
               {:error, :float_not_allowed}
    end

    test "integers beyond 2^53-1", %{f: f} do
      max = 9_007_199_254_740_991
      assert {:ok, _} = SignedMessage.build(%{f | "generation" => max})

      assert SignedMessage.build(%{f | "generation" => max + 1}) ==
               {:error, :integer_out_of_range}

      assert SignedMessage.build(%{f | "principal" => %{"n" => -(max + 1)}}) ==
               {:error, :integer_out_of_range}
    end

    test "atom-vs-string key collision and duplicates", %{f: f} do
      assert SignedMessage.build(Map.put(f, :kid, "other")) == {:error, :duplicate_key}
      nested = %{f | "principal" => %{"a" => 1, a: 2}}
      assert SignedMessage.build(nested) == {:error, :duplicate_key}
    end

    test "missing, unknown, and mistyped fields", %{f: f} do
      assert SignedMessage.build(Map.delete(f, "audience")) == {:error, :missing_field}
      assert SignedMessage.build(Map.put(f, "extra", 1)) == {:error, :unknown_field}
      assert SignedMessage.build(%{f | "nonce" => 5}) == {:error, :bad_field_type}
      assert SignedMessage.build(%{f | "expires" => -1}) == {:error, :bad_field_type}
      assert SignedMessage.build(%{f | "principal" => nil}) == {:error, :bad_field_type}
      assert SignedMessage.build([]) == {:error, :not_an_object}
    end

    test "deep, oversize, non-UTF-8, unsupported values", %{f: f} do
      deep = Enum.reduce(1..20, "x", fn _, acc -> [acc] end)
      assert SignedMessage.build(%{f | "principal" => deep}) == {:error, :too_deep}
      big = String.duplicate("a", 20_000)
      assert SignedMessage.build(%{f | "principal" => big}) == {:error, :oversize}
      wide = for i <- 1..3000, do: i
      assert SignedMessage.build(%{f | "principal" => wide}) == {:error, :oversize}

      assert SignedMessage.build(%{f | "principal" => <<0xFF, 0xFE>>}) ==
               {:error, :invalid_string}

      assert SignedMessage.build(%{f | "principal" => {:tuple}}) == {:error, :unsupported_value}
      assert SignedMessage.build(%{f | "principal" => :an_atom}) == {:error, :unsupported_value}
      assert SignedMessage.build(%{f | "principal" => self()}) == {:error, :unsupported_value}
    end
  end

  test "parse strips the domain and refuses a wrong domain" do
    {:ok, bytes} = SignedMessage.build(Fixtures.base_fields("ES256", "k"))
    assert {:ok, %{"kid" => "k"}} = SignedMessage.parse(bytes)
    <<_::binary-size(19), rest::binary>> = bytes
    assert SignedMessage.parse("SA2A-C2-APPROVAL-v2" <> rest) == {:error, :bad_domain}
    assert SignedMessage.parse(rest) == {:error, :bad_domain}

    assert SignedMessage.parse("SA2A-C2-APPROVAL-v1" <> <<0>> <> "not json") ==
             {:error, :malformed_message}
  end
end
