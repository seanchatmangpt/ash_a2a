defmodule AshA2A.Attestation.GateTest do
  @moduledoc """
  Chicago-style tests: real :crypto ECDSA P-256 sign/verify round-trips, no
  mocks. Asserts on final typed outcomes (tokens, {:refused, reason}).
  """
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, Key}

  @now 1_700_000_000

  defp fresh_claims(nonce, extra) do
    Map.merge(
      %{
        "nonce" => nonce,
        "device_id" => "device-abc",
        "os_fingerprint" => "google/raven/raven:13/TQ3A.230901.001",
        "is_virtual" => false,
        "issued_at" => @now - 10
      },
      extra
    )
  end

  defp signed(extra \\ %{}, nonce \\ "nonce-123") do
    key = Key.generate()
    token = Key.sign(fresh_claims(nonce, extra), key)
    {key, token}
  end

  describe "Key sign/verify round-trip" do
    test "sign then verify with the matching public key returns the claims" do
      key = Key.generate()
      claims = %{"nonce" => "n1", "device_id" => "d1"}
      token = Key.sign(claims, key)
      assert {:ok, ^claims} = Key.verify(token, key)
    end

    test "tampered payload is refused with :bad_signature" do
      key = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, key)
      [pfx, payload, sig] = String.split(token, ".", parts: 3)

      # Tamper the payload (flip a byte of the JSON by re-encoding altered claims)
      forged_payload =
        payload
        |> then(fn p -> Base.url_decode64!(p, padding: false) end)
        |> String.replace("n1", "n2")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, sig], ".")
      assert {:error, :bad_signature} = Key.verify(tampered, key)
    end

    test "signature from a different key is refused" do
      k1 = Key.generate()
      k2 = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, k1)
      assert {:error, :bad_signature} = Key.verify(token, k2)
    end

    test "malformed token is typed-refused" do
      key = Key.generate()
      assert {:error, :malformed_token} = Key.verify("not-a-token", key)
    end
  end

  describe "verify_enclave/2" do
    test "fresh, real-shaped payload passes" do
      {key, token} = signed()
      assert {:ok, %{"device_id" => "device-abc"}} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "virtual claim triggers {:refused, :emulator_detected}" do
      {key, token} = signed(%{"is_virtual" => true})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "emulator-flavored os_fingerprint triggers :emulator_detected" do
      {key, token} = signed(%{"os_fingerprint" => "google/sdk_gphone_x86/generic:13"})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "known emulator package triggers :emulator_detected" do
      {key, token} = signed(%{"installed_packages" => ["com.bluestacks.something"]})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "tampered token is refused with :bad_signature" do
      {key, token} = signed()
      [pfx, payload, _sig] = String.split(token, ".", parts: 3)

      forged_payload =
        Base.url_decode64!(payload, padding: false)
        |> String.replace("\"device-abc\"", "\"device-hax\"")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, "AAAA"], ".")
      assert {:refused, :bad_signature} = Gate.verify_enclave({tampered, "nonce-123"}, key: key)
    end

    test "nonce mismatch is typed-refused" do
      {key, token} = signed()
      assert {:refused, :nonce_mismatch} = Gate.verify_enclave({token, "other-nonce"}, key: key)
    end
  end

  describe "verify_freshness/2" do
    test "fresh claim passes" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 30}, now: @now)
    end

    test "stale claim is refused" do
      assert {:refused, :stale} = Gate.verify_freshness(%{"issued_at" => @now - 91}, now: @now)
    end

    test "boundary: exactly max_staleness_sec old passes, +1s refuses" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 90}, now: @now)
      assert {:refused, :stale} = Gate.verify_freshness(%{"issued_at" => @now - 91}, now: @now, max_staleness_sec: 90)
    end

    test "missing issued_at is malformed" do
      assert {:refused, :malformed_token} = Gate.verify_freshness(%{}, now: @now)
    end

    test "future-issued beyond small skew is refused :clock_skew (typed, not :stale)" do
      assert {:refused, :clock_skew} = Gate.verify_freshness(%{"issued_at" => @now + 60}, now: @now)
    end

    test "boundary: exactly 5s forward skew accepted, +1s refused" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now + 5}, now: @now)
      assert {:refused, :clock_skew} = Gate.verify_freshness(%{"issued_at" => @now + 6}, now: @now)
    end
  end

  describe "verify_sensor_metadata/2" do
    defp good_sensor do
      %{
        "camera_make" => "Apple",
        "camera_model" => "iPhone 15 Pro",
        "gps" => %{"lat" => 35.68, "lon" => 139.76, "timestamp" => @now - 20, "accuracy" => 8.0}
      }
    end

    test "well-formed fresh sensor metadata passes" do
      assert :ok = Gate.verify_sensor_metadata(good_sensor(), now: @now)
    end

    test "missing camera_make is spoofed_payload" do
      claims = Map.delete(good_sensor(), "camera_make")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "missing gps block is spoofed_payload" do
      claims = Map.delete(good_sensor(), "gps")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "absurd gps accuracy is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "accuracy"], 5_000_000.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "out-of-range lat is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "lat"], 123.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "stale gps timestamp is refused :stale" do
      claims = put_in(good_sensor(), ["gps", "timestamp"], @now - 300)
      assert {:refused, :stale} = Gate.verify_sensor_metadata(claims, now: @now)
    end
  end

  describe "verify_gps_trajectory/1 (mock-GPS rejection)" do
    defp obs(lat, lon, ts), do: %{"lat" => lat, "lon" => lon, "timestamp" => ts}

    test "realistic walk passes" do
      # Tokyo station -> ~200m away, 30s later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6830, 139.7690, @now + 30)
               ])
    end

    test "teleport Tokyo->Sapporo within 60s is :gps_impossible_jump" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 45)
               ])
    end

    test "sub-threshold jump Tokyo->Osaka (~392km < 500km) is allowed" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(34.6937, 135.5023, @now + 45)
               ])
    end

    test "large jump with >60s elapsed is allowed (flight-speed travel)" do
      # Same Tokyo->Sapporo jump but 2 hours later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 7200)
               ])
    end

    test "unsorted observations are sorted before checking" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(43.0618, 141.3545, @now + 45),
                 obs(35.6812, 139.7671, @now)
               ])
    end

    test "identical-coordinate no-movement sequence is lawful (replay closed by nonce ledger, not geometry)" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    # Platform law (OTP 28): NaN floats are unconstructible — float bit-pattern
    # matches, :math domain errors (sqrt(-1), log(0)), arithmetic overflow, and
    # binary_to_term NEW_FLOAT_EXT all raise. The substrate itself refuses NaN,
    # so the reachable form of this attack here is the adversarially huge
    # integer below (which would crash :math on unguarded code paths).
    test "sqrt(-1) raises badarg (platform law: :math never returns NaN)" do
      assert_raise ArithmeticError, fn -> :math.sqrt(-1.0) end
    end

    test "adversarially huge integer coordinate is refused :spoofed_payload (no :math badarg crash)" do
      huge = String.duplicate("9", 400) |> String.to_integer()

      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs(huge, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    test "non-numeric coordinate string is refused :spoofed_payload" do
      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs("35.6812", 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end
  end

  # ECDSA malleability: (r, s) and (r, n - s) both verify against the same
  # pubkey; the low-s gate must refuse the malleated twin before crypto.
  describe "signature malleability (canonical low-s)" do
    @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    test "canonical token verifies" do
      {key, token} = signed()
      assert {:ok, _} = Key.verify(token, key)
    end

    test "malleated twin (s' = n - s) is refused :non_canonical_signature" do
      {key, token} = signed()
      twin = malleate(token)

      # the twin differs from the original but is still a valid ECDSA signature
      assert twin != token
      assert {:error, :non_canonical_signature} = Key.verify(twin, key)
    end

    test "malleated twin through verify_enclave is {:refused, :non_canonical_signature}" do
      {key, token} = signed()
      assert {:refused, :non_canonical_signature} = Gate.verify_enclave({malleate(token), "nonce-123"}, key: key)
    end

    defp malleate(token) do
      [pfx, payload, sig] = String.split(token, ".", parts: 3)
      der = Base.url_decode64!(sig, padding: false)
      <<0x30, _len, body::binary>> = der
      <<0x02, rlen, r::binary-size(rlen), 0x02, slen, s_bin::binary-size(slen)>> = body

      s = :binary.decode_unsigned(s_bin)
      s2_bin = der_int(@n - s)
      body2 = <<0x02, byte_size(r), r::binary, 0x02, byte_size(s2_bin), s2_bin::binary>>
      der2 = <<0x30, byte_size(body2), body2::binary>>

      Enum.join([pfx, payload, Base.url_encode64(der2, padding: false)], ".")
    end

    defp der_int(v) do
      bin = :binary.encode_unsigned(v)

      case bin do
        <<first, _::binary>> when first >= 128 -> <<0, bin::binary>>
        <<0, _::binary>> = padded -> padded
        _ -> bin
      end
    end
  end

end
