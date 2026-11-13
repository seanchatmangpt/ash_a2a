defmodule AshA2A.Ingress.Lane01IngressHardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Key
  alias AshA2A.Ingress.Channel

  @now 1_700_000_000

  defp gps(lat, lon, ts), do: %{"lat" => lat, "lon" => lon, "accuracy" => 12.0, "timestamp" => ts}

  defp checkin(key, nonce, now, g) do
    claims = %{
      "nonce" => nonce,
      "issued_at" => now,
      "os_fingerprint" => "linux",
      "installed_packages" => [],
      "is_virtual" => false,
      "gps" => g
    }

    %{
      coordinator: "c",
      nonce: nonce,
      device_token: Key.sign(claims, key),
      timestamp: now,
      gps: g,
      camera_make: "Google",
      camera_model: "Pixel 8"
    }
  end

  setup do: {:ok, key: Key.generate()}

  test "nonce ledger is FIFO-bounded at 1024", %{key: key} do
    state =
      Enum.reduce(1..1025, Channel.empty_state(), fn i, st ->
        {{:ok, _}, st} =
          Channel.ingest(st, checkin(key, "n#{i}", @now, gps(35.0, 139.0, @now)),
            key: key,
            now: @now
          )

        st
      end)

    assert length(state.consumed_nonces["c"].order) == 1024
    # n1 evicted: no longer replay-refused (ledger weakening documented); n1025 still refused.
    {{:refused, :nonce_replayed}, _} =
      Channel.ingest(state, checkin(key, "n1025", @now, gps(35.0, 139.0, @now)),
        key: key,
        now: @now
      )

    refute MapSet.member?(state.consumed_nonces["c"].set, "n1")
  end

  test "unknown refusal shape folds to :spoofed_payload instead of crashing", %{key: key} do
    event = %{checkin(key, "x", @now, gps(35.0, 139.0, @now)) | device_token: "v1.!!!.@@@"}

    assert {{:refused, :spoofed_payload}, _} =
             Channel.ingest(Channel.empty_state(), event, key: key, now: @now)
  end

  test "approved grants flow through ingest/3 to the trajectory check", %{key: key} do
    grant = %{
      grant_id: "g",
      org_id: "o",
      identifier_or_cidr: "i",
      ttl_hours: 24,
      approved_at: @now - 60,
      area: %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0}
    }

    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    t2 = @now + 30
    ev = checkin(key, "b", t2, gps(47.0, -115.0, t2))

    assert {{:refused, :gps_impossible_jump}, _} = Channel.ingest(st, ev, key: key, now: t2)
    assert {{:ok, _}, _} = Channel.ingest(st, ev, key: key, now: t2, approved_grants: [grant])
  end

  test "unsigned far-future/stale event timestamp cannot skip the jump check", %{key: key} do
    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    t2 = @now + 30
    ev = %{checkin(key, "b", t2, gps(47.0, -115.0, t2)) | timestamp: t2 + 10_000}
    assert {{:refused, :clock_skew}, _} = Channel.ingest(st, ev, key: key, now: t2)
  end

  test "out-of-order older event does not overwrite last_known", %{key: key} do
    {{:ok, _}, st} =
      Channel.ingest(Channel.empty_state(), checkin(key, "a", @now, gps(37.0, -122.0, @now)),
        key: key,
        now: @now
      )

    older = @now - 20

    {{:ok, _}, st} =
      Channel.ingest(st, checkin(key, "b", older, gps(37.0, -122.0, older)), key: key, now: @now)

    assert st.last_known["c"]["timestamp"] == @now
  end
end
