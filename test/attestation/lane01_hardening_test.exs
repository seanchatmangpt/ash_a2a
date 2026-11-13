defmodule AshA2A.Attestation.Lane01HardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, GateGrantAllowlist, Key}

  @now 1_700_000_000

  defp b64(d), do: Base.url_encode64(d, padding: false)

  defp signed_raw(raw_payload, key) do
    sig = :crypto.sign(:ecdsa, :sha256, raw_payload, [key.priv, :prime256v1])
    "v1." <> b64(raw_payload) <> "." <> b64(sig)
  end

  test "bad base64 token yields typed :malformed_token" do
    key = Key.generate()
    assert {:error, :malformed_token} = Key.verify("v1.!!!.@@@", key)
    assert {:refused, :malformed_token} = Gate.verify_enclave({"v1.!!!.@@@", "n"}, key)
  end

  test "non-JSON and non-map signed payloads yield typed errors" do
    key = Key.generate()
    # Retry until the random signature is low-s (verify enforces canonical form).
    non_json = find_canonical("not json at all", key)
    assert {:error, :malformed_token} = Key.verify(non_json, key)
    list_payload = find_canonical("[1,2,3]", key)
    assert {:error, :malformed_token} = Key.verify(list_payload, key)
  end

  defp find_canonical(raw, key) do
    Enum.find_value(1..64, fn _ ->
      tok = signed_raw(raw, key)

      case Key.verify(tok, key) do
        {:error, :non_canonical_signature} -> nil
        _ -> tok
      end
    end)
  end

  test "bad private key is {:error, :bad_key}; verify without :pub or non-binary token is typed" do
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{priv: :nope, pub: "x"})
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{})
    assert {:error, :malformed_token} = Key.verify("v1.a.b", %{})
    assert {:error, :malformed_token} = Key.verify(nil, Key.generate())
    assert {:refused, :malformed_token} = Gate.verify_enclave({nil, "n"}, nil)
  end

  test "emulator detection type guards refuse non-binary fingerprint / non-list packages" do
    key = Key.generate()

    for extra <- [%{"os_fingerprint" => 42}, %{"installed_packages" => "com.bluestacks"}] do
      token = Key.sign(Map.merge(%{"nonce" => "n"}, extra), key)
      assert {:refused, :spoofed_payload} = Gate.verify_enclave({token, "n"}, key)
    end

    token = Key.sign(%{"nonce" => "n", "installed_packages" => ["com.android.fly.x"]}, key)
    assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "n"}, key)
  end

  defp grant(extra \\ %{}) do
    Map.merge(
      %{
        grant_id: "g",
        org_id: "org-1",
        identifier_or_cidr: "id-1",
        ttl_hours: 24,
        approved_at: @now - 60,
        area: %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0}
      },
      extra
    )
  end

  defp jumping do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "grant missing :area is not covering; no crash" do
    g = Map.delete(grant(), :area)
    assert {:refused, :gps_impossible_jump} = Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "unsorted observations are sorted like the base check" do
    assert :ok = Gate.verify_gps_trajectory(Enum.reverse(jumping()), approved_grants: [grant()], now: @now)
  end

  test "future approved_at grant is rejected" do
    g = grant(%{approved_at: @now + 1000})
    assert {:refused, :gps_impossible_jump} = Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "grants are scoped by org_id / identifier when supplied" do
    assert :ok = Gate.verify_gps_trajectory(jumping(), approved_grants: [grant()], now: @now, org_id: "org-1")
    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [grant()], now: @now, org_id: "org-2")
    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [grant()], now: @now, identifier: "other")
    assert :ok = GateGrantAllowlist.override?(jumping(), [grant()], @now, identifier: "id-1")
  end

  test "malformed grant entries are ignored" do
    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [:junk, %{}, nil], now: @now)
  end
end
