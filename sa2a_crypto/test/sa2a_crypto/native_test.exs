defmodule Sa2aCrypto.NativeTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.{DER, Native}
  import Sa2aCrypto.Fixtures, only: [unhex: 1]

  describe "Ed25519 known answers (RFC 8032 section 7.1)" do
    @vectors [
      {"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
       "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
       "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"},
      {"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
       "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
       "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"}
    ]

    for {{sk, pk, msg, sig}, i} <- Enum.with_index(@vectors, 1) do
      test "vector #{i} verifies and flips are refused" do
        {sk, pk, msg, sig} =
          {unhex(unquote(sk)), unhex(unquote(pk)), unhex(unquote(msg)), unhex(unquote(sig))}

        assert {^pk, _} = :crypto.generate_key(:eddsa, :ed25519, sk)
        assert Native.verify("EdDSA", msg, sig, pk) == :ok
        assert {:ok, ^sig} = Native.sign("EdDSA", msg, sk)

        <<b, rest::binary>> = sig

        assert Native.verify("EdDSA", msg, <<Bitwise.bxor(b, 1), rest::binary>>, pk) ==
                 {:error, :bad_signature}

        assert Native.verify("EdDSA", msg <> "x", sig, pk) == {:error, :bad_signature}

        assert Native.verify("EdDSA", msg, binary_part(sig, 0, 63), pk) ==
                 {:error, :bad_signature}
      end
    end

    test "wrong-size keys return :bad_key, never raise" do
      sig = :binary.copy(<<1>>, 64)

      for k <- [
            <<>>,
            <<1>>,
            :binary.copy(<<1>>, 31),
            :binary.copy(<<1>>, 33),
            :binary.copy(<<1>>, 64),
            nil,
            42
          ] do
        assert Native.verify("EdDSA", "m", sig, k) == {:error, :bad_key}
      end
    end
  end

  describe "ES256" do
    setup do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      msg = "sa2a p256 message"
      sig = :crypto.sign(:ecdsa, :sha256, msg, [priv, :secp256r1])
      {:ok, pub: pub, priv: priv, msg: msg, sig: sig}
    end

    test "valid signature verifies (independent :crypto.sign oracle)", c do
      assert Native.verify("ES256", c.msg, c.sig, c.pub) == :ok
      assert {:ok, s2} = Native.sign("ES256", c.msg, c.priv)
      assert :crypto.verify(:ecdsa, :sha256, c.msg, s2, [c.pub, :secp256r1])
    end

    test "SPKI-wrapped public key is accepted", c do
      {:ok, spki} = Sa2aCrypto.KeyRef.spki("ES256", c.pub)
      assert Native.verify("ES256", c.msg, c.sig, spki) == :ok
    end

    test "bit flips in message and signature are refused", c do
      assert Native.verify("ES256", c.msg <> "!", c.sig, c.pub) == {:error, :bad_signature}

      for i <- 0..(byte_size(c.sig) - 1) do
        <<pre::binary-size(^i), b, post::binary>> = c.sig
        bad = <<pre::binary, Bitwise.bxor(b, 0x01), post::binary>>
        assert Native.verify("ES256", c.msg, bad, c.pub) == {:error, :bad_signature}, "byte #{i}"
      end
    end

    test "high-s and low-s twins both verify (no low-s requirement)", c do
      {:ok, {r, s}} = DER.parse_ecdsa_sig(c.sig)
      n = DER.n()
      low = min(s, n - s)
      high = n - low
      assert low != high
      lo = DER.encode_ecdsa_sig(r, low)
      hi = DER.encode_ecdsa_sig(r, high)
      assert lo != hi
      assert Native.verify("ES256", c.msg, lo, c.pub) == :ok
      assert Native.verify("ES256", c.msg, hi, c.pub) == :ok
    end

    test "wrong key is refused", c do
      {other, _} = :crypto.generate_key(:ecdh, :secp256r1)
      assert Native.verify("ES256", c.msg, c.sig, other) == {:error, :bad_signature}
    end

    test "wrong-size, compressed, off-curve, and garbage public keys return :bad_key", c do
      <<4, x::binary-size(32), y::binary-size(32)>> = c.pub

      off =
        <<4, x::binary,
          (:binary.decode_unsigned(y) + 1) |> :binary.encode_unsigned() |> pad32()::binary>>

      keys = [
        <<>>,
        <<4>>,
        binary_part(c.pub, 0, 64),
        c.pub <> <<0>>,
        <<2, x::binary>>,
        <<4, 0::256, 0::256>>,
        off,
        :binary.copy(<<0xFF>>, 65),
        nil,
        :ok
      ]

      for k <- keys,
          do: assert(Native.verify("ES256", c.msg, c.sig, k) == {:error, :bad_key}, inspect(k))
    end

    defp pad32(b), do: :binary.copy(<<0>>, 32 - byte_size(b)) <> b

    test "strict DER: every malformed encoding is refused, at the DER layer and by verify", c do
      {:ok, {r, s}} = DER.parse_ecdsa_sig(c.sig)
      n = DER.n()
      good = DER.encode_ecdsa_sig(r, s)
      <<0x30, len, body::binary>> = good

      ri = int(r)
      si = int(s)
      wrap = fn b -> <<0x30, byte_size(b)>> <> b end

      cases = [
        {:trailing_bytes, good <> <<0>>},
        {:trailing_bytes, <<0x30, len + 1>> <> body <> <<0>>} |> fix_trailing(),
        {:non_minimal_length, <<0x30, 0x81, len>> <> body},
        {:negative_integer, wrap.(<<0x02, 1, 0x80>> <> si)},
        {:non_minimal_integer, wrap.(<<0x02, 2, 0x00, 0x01>> <> si)},
        {:out_of_range, wrap.(<<0x02, 1, 0x00>> <> si)},
        {:out_of_range, wrap.(ri <> <<0x02, 1, 0x00>>)},
        {:out_of_range, DER.encode_ecdsa_sig(n, s)},
        {:out_of_range, DER.encode_ecdsa_sig(r, n)},
        {:out_of_range, DER.encode_ecdsa_sig(r, n + 5)},
        {:bad_der, <<0x31>> <> binary_part(good, 1, byte_size(good) - 1)},
        {:bad_der, <<0x30, 0x80>> <> body <> <<0, 0>>},
        {:truncated, binary_part(good, 0, byte_size(good) - 1)},
        {:bad_der, <<>>},
        {:bad_der, <<0x30>>},
        {:bad_der, wrap.(<<0x04, 1, 1>> <> si)}
      ]

      for {reason, der} <- cases do
        assert {:error, got} = DER.parse_ecdsa_sig(der)
        assert got == reason, "expected #{reason}, got #{got} for #{Base.encode16(der)}"
        assert Native.verify("ES256", c.msg, der, c.pub) == {:error, :bad_signature}
      end

      # sanity: the untouched encoding is accepted
      assert {:ok, {^r, ^s}} = DER.parse_ecdsa_sig(good)
    end

    defp fix_trailing({r, v}), do: {r, v}

    defp int(i) do
      b = :binary.encode_unsigned(i)
      b = if :binary.first(b) >= 0x80, do: <<0>> <> b, else: b
      <<0x02, byte_size(b)>> <> b
    end
  end

  describe "post-quantum suites via OTP atoms" do
    test "capability probe reflects :crypto.supports" do
      assert Native.pq_available?(:mldsa65) == :mldsa65 in :crypto.supports(:public_keys)
      refute Native.pq_available?(:mldsa99)
      refute Native.pq_available?(nil)
    end

    for alg <- ["ML-DSA-44", "ML-DSA-65", "ML-DSA-87", "SLH-DSA-SHA2-128F"] do
      test "#{alg} round trip, tamper, and wrong-size key" do
        alg = unquote(alg)
        {pub, priv} = Sa2aCrypto.Fixtures.keypair(alg)
        sig = Sa2aCrypto.Fixtures.raw_sign(alg, "pq msg", priv)
        assert Native.verify(alg, "pq msg", sig, pub) == :ok
        assert Native.verify(alg, "pq msg!", sig, pub) == {:error, :bad_signature}
        <<b, rest::binary>> = sig

        assert Native.verify(alg, "pq msg", <<Bitwise.bxor(b, 1), rest::binary>>, pub) ==
                 {:error, :bad_signature}

        assert Native.verify(alg, "pq msg", sig, binary_part(pub, 0, byte_size(pub) - 1)) ==
                 {:error, :bad_key}

        assert Native.verify(alg, "pq msg", sig, pub <> <<0>>) == {:error, :bad_key}
        assert Native.verify(alg, "pq msg", sig, <<>>) == {:error, :bad_key}
      end
    end

    test "hybrid requires both components" do
      alg = "ES256+ML-DSA-65"
      {pub, priv} = Sa2aCrypto.Fixtures.keypair(alg)
      sig = Sa2aCrypto.Fixtures.raw_sign(alg, "h", priv)
      assert Native.verify(alg, "h", sig, pub) == :ok
      {cpub, ppub} = pub
      {other_c, _} = :crypto.generate_key(:ecdh, :secp256r1)
      assert Native.verify(alg, "h", sig, {other_c, ppub}) == {:error, :bad_signature}
      {other_p, _} = :crypto.generate_key(:mldsa65, [])
      assert Native.verify(alg, "h", sig, {cpub, other_p}) == {:error, :bad_signature}
      assert Native.verify(alg, "h", sig, cpub) == {:error, :bad_key}
      # classical-only signature under a hybrid alg
      <<l::32, csig::binary-size(l), _::binary>> = sig
      assert Native.verify(alg, "h", csig, pub) == {:error, :bad_signature}
    end

    test "unregistered algorithms are refused" do
      assert Native.verify("RS256", "m", "s", "k") == {:error, :unsupported_algorithm}
      assert Native.verify("ML-DSA-99", "m", "s", "k") == {:error, :unsupported_algorithm}
      refute Native.supports?("RS256")
    end
  end
end
