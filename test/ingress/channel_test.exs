defmodule AshA2A.Ingress.ChannelTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Key
  alias AshA2A.Ingress.Channel

  @now 1_700_000_000

  setup do
    key = Key.generate()
    {:ok, key: key, state: Channel.empty_state()}
  end

  defp device_claims(opts \\ []) do
    now = Keyword.get(opts, :now, @now)
    gps = Keyword.get(opts, :gps, %{"lat" => 35.6812, "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => now})

    %{
      "nonce" => Keyword.get(opts, :nonce, "nonce-1"),
      "issued_at" => now,
      "os_fingerprint" => "linux/x86_64",
      "installed_packages" => [],
      "is_virtual" => false,
      "gps" => gps
    }
  end

  defp event(opts) do
    now = Keyword.get(opts, :now, @now)

    %{
      coordinator: Keyword.get(opts, :coordinator, "coord-A"),
      nonce: Keyword.get(opts, :nonce, "nonce-1"),
      device_token: Keyword.fetch!(opts, :token),
      timestamp: now,
      gps: Keyword.get(opts, :gps, %{"lat" => 35.6812, "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => now}),
      camera_make: Keyword.get(opts, :camera_make, "Google"),
      camera_model: Keyword.get(opts, :camera_model, "Pixel 8")
    }
  end

  test "admits a correctly-signed fresh on-site check-in and normalizes the event", %{key: key, state: state} do
    token = Key.sign(device_claims(), key)
    {{:ok, validated}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)

    assert validated.coordinator == "coord-A"
    assert validated.timestamp == @now
    assert validated.ingested_at == @now
    assert validated.camera_make == "Google"
    assert validated.claims["nonce"] == "nonce-1"
    assert validated.gps["lat"] == 35.6812
    assert state2.last_known["coord-A"]["timestamp"] == @now
    assert Channel.stats(state2) == %{}
  end

  test "refuses a token signed by a foreign key with :bad_signature", %{key: key, state: state} do
    rogue = Key.generate()
    token = Key.sign(device_claims(), rogue)

    {{:refused, reason}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert reason == :bad_signature
    assert Channel.stats(state2) == %{bad_signature: 1}
  end

  test "refuses an emulator-declaring device with :emulator_detected", %{key: key, state: state} do
    claims = device_claims() |> Map.put("is_virtual", true)
    token = Key.sign(claims, key)

    {{:refused, :emulator_detected}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert Channel.stats(state2) == %{emulator_detected: 1}
  end

  test "refuses an attestation signed in the past with :stale", %{key: key, state: state} do
    token = Key.sign(device_claims(now: @now - 3600), key)

    {{:refused, :stale}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert Channel.stats(state2) == %{stale: 1}
  end

  test "refuses sensor metadata without camera claims as :spoofed_payload", %{key: key, state: state} do
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, state2} =
      Channel.ingest(state, event(token: token, camera_make: ""), key: key, now: @now)

    assert Channel.stats(state2) == %{spoofed_payload: 1}
  end

  test "refuses absurd GPS accuracy as :spoofed_payload", %{key: key, state: state} do
    token = Key.sign(device_claims(), key)

    bad_gps = %{"lat" => 35.6812, "lon" => 139.7671, "accuracy" => 500_000.0, "timestamp" => @now}

    {{:refused, :spoofed_payload}, _} =
      Channel.ingest(state, event(token: token, gps: bad_gps), key: key, now: @now)
  end

  test "refuses a nonce mismatch as :spoofed_payload (folded vocabulary)", %{key: key, state: state} do
    token = Key.sign(device_claims(nonce: "nonce-1"), key)

    {{:refused, reason}, state2} =
      Channel.ingest(state, event(token: token, nonce: "nonce-OTHER"), key: key, now: @now)

    assert reason == :spoofed_payload
    assert Channel.stats(state2) == %{spoofed_payload: 1}
  end

  test "refuses a structurally-broken token as :spoofed_payload", %{key: key, state: state} do
    {{:refused, :spoofed_payload}, _} = Channel.ingest(state, event(token: "garbage"), key: key, now: @now)
  end

  test "refuses consecutive-event GPS teleport across two ingests", %{key: key, state: state} do
    # Fix 1: Tokyo, fresh.
    t1 = Key.sign(device_claims(nonce: "n1"), key)
    e1 = event(token: t1, nonce: "n1")

    {{:ok, _}, state1} = Channel.ingest(state, e1, key: key, now: @now)

    # Fix 2: 45 seconds later, Lisbon (~11,000 km away) — physically impossible.
    t2t = @now + 45

    lisbon = %{"lat" => 38.7223, "lon" => -9.1393, "accuracy" => 15.0, "timestamp" => t2t}
    t2 = Key.sign(device_claims(nonce: "n2", now: t2t, gps: lisbon), key)
    e2 = event(token: t2, nonce: "n2", now: t2t, gps: lisbon)

    {{:refused, :gps_impossible_jump}, state2} = Channel.ingest(state1, e2, key: key, now: t2t)

    # Fix 3: a plausible short hop (Tokyo -> Yokohama, ~27 km in 60s) is admitted
    # and updates the last-known fix.
    t3t = t2t + 60

    yokohama = %{"lat" => 35.4437, "lon" => 139.6380, "accuracy" => 10.0, "timestamp" => t3t}
    t3 = Key.sign(device_claims(nonce: "n3", now: t3t, gps: yokohama), key)
    e3 = event(token: t3, nonce: "n3", now: t3t, gps: yokohama)

    {{:ok, validated}, state3} = Channel.ingest(state2, e3, key: key, now: t3t)
    assert validated.gps["lat"] == 35.4437
    assert state3.last_known["coord-A"]["lat"] == 35.4437

    assert Channel.stats(state3) == %{gps_impossible_jump: 1}
  end

  test "refusals accumulate across reasons and coordinators are independent", %{key: key} do
    state = Channel.empty_state()

    rogue = Key.generate()

    e1 = event(token: Key.sign(device_claims(nonce: "a"), rogue), nonce: "a", coordinator: "c1")
    e2 = event(token: Key.sign(device_claims(nonce: "b", now: @now - 9999), key), nonce: "b", coordinator: "c2")

    {_, state1} = Channel.ingest(state, e1, key: key, now: @now)
    {_, state2} = Channel.ingest(state1, e2, key: key, now: @now)

    assert Channel.stats(state2) == %{:bad_signature => 1, :stale => 1}
    assert state2.last_known == %{}
  end

  test "a missing signature key raises KeyError (fail-loud configuration error)", %{state: state} do
    assert_raise KeyError, fn ->
      Channel.ingest(state, event(token: "x"), now: @now)
    end
  end

  # --- F7 defenses ---

  describe "nonce replay (per-coordinator consumed-nonce ledger)" do
    test "a successfully-ingested event replayed verbatim is {:refused, :nonce_replayed}", %{key: key, state: state} do
      token = Key.sign(device_claims(nonce: "n1"), key)
      e = event(token: token, nonce: "n1")

      {{:ok, _}, state1} = Channel.ingest(state, e, key: key, now: @now)
      {{:refused, :nonce_replayed}, state2} = Channel.ingest(state1, e, key: key, now: @now + 1)

      assert Channel.stats(state2) == %{nonce_replayed: 1}
    end

    test "replay of a DIFFERENT token under an already-consumed nonce is refused", %{key: key, state: state} do
      t1 = Key.sign(device_claims(nonce: "n1"), key)
      {{:ok, _}, state1} = Channel.ingest(state, event(token: t1, nonce: "n1"), key: key, now: @now)

      t2 = Key.sign(device_claims(nonce: "n1", now: @now + 10), key)
      {{:refused, :nonce_replayed}, _} = Channel.ingest(state1, event(token: t2, nonce: "n1"), key: key, now: @now + 10)
    end

    test "replay refusal happens BEFORE crypto work (forged twin of consumed nonce refused identically)", %{key: key, state: state} do
      t1 = Key.sign(device_claims(nonce: "n1"), key)
      {{:ok, _}, state1} = Channel.ingest(state, event(token: t1, nonce: "n1"), key: key, now: @now)

      rogue = Key.generate()
      {{:refused, :nonce_replayed}, _} = Channel.ingest(state1, event(token: Key.sign(device_claims(nonce: "n1"), rogue), nonce: "n1"), key: key, now: @now)
    end

    test "nonce ledgers are per-coordinator (same nonce from another coordinator is fresh)", %{key: key, state: state} do
      t1 = Key.sign(device_claims(nonce: "n1", now: @now), key)
      {{:ok, _}, state1} = Channel.ingest(state, event(token: t1, nonce: "n1", coordinator: "c1"), key: key, now: @now)

      t2 = Key.sign(device_claims(nonce: "n1", now: @now), key)
      {{:ok, _}, _} = Channel.ingest(state1, event(token: t2, nonce: "n1", coordinator: "c2"), key: key, now: @now)
    end

    test "a refused ingest does not consume its nonce (retry with corrected metadata is allowed)", %{key: key, state: state} do
      token = Key.sign(device_claims(), key)

      {{:refused, :spoofed_payload}, state1} =
        Channel.ingest(state, event(token: token, camera_make: ""), key: key, now: @now)

      {{:ok, _}, _} = Channel.ingest(state1, event(token: token), key: key, now: @now)
    end
  end

  test "future-issued attestation beyond skew is {:refused, :clock_skew}", %{key: key, state: state} do
    token = Key.sign(device_claims(now: @now + 60), key)
    {{:refused, :clock_skew}, state2} = Channel.ingest(state, event(token: token), key: key, now: @now)
    assert Channel.stats(state2) == %{clock_skew: 1}
  end

  test "malleated-signature token is {:refused, :non_canonical_signature} (not :bad_signature)", %{key: key, state: state} do
    token = Key.sign(device_claims(nonce: "nm"), key)
    twin = malleate(token)

    {{:refused, :non_canonical_signature}, state2} =
      Channel.ingest(state, event(token: twin, nonce: "nm"), key: key, now: @now)

    assert Channel.stats(state2) == %{non_canonical_signature: 1}
  end

  # Platform law (OTP 28): NaN floats are unconstructible — float bit-pattern
  # matches, :math domain errors, and arithmetic overflow all raise. The
  # reachable form of the "non-finite coordinate" attack on this substrate is
  # an adversarially huge integer, which the gate must refuse without letting
  # :math crash the caller.
  test "adversarially huge integer coordinate is {:refused, :spoofed_payload} without crashing", %{key: key, state: state} do
    huge = String.duplicate("9", 400) |> String.to_integer()
    bad_gps = %{"lat" => huge, "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, _} = Channel.ingest(state, event(token: token, gps: bad_gps), key: key, now: @now)
  end

  test "coordinate supplied as a string is {:refused, :spoofed_payload}", %{key: key, state: state} do
    string_gps = %{"lat" => "35.6812", "lon" => 139.7671, "accuracy" => 12.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, _} = Channel.ingest(state, event(token: token, gps: string_gps), key: key, now: @now)
  end

  test "signed-subset confusion: event GPS disagreeing with signed claims GPS is {:refused, :spoofed_payload}", %{key: key, state: state} do
    # Token signed over a Tokyo fix; attacker submits the same token with a
    # Lisbon event fix — the signature does not cover the event, so the
    # channel must bind them.
    lisbon = %{"lat" => 38.7223, "lon" => -9.1393, "accuracy" => 15.0, "timestamp" => @now}
    token = Key.sign(device_claims(), key)

    {{:refused, :spoofed_payload}, state2} =
      Channel.ingest(state, event(token: token, gps: lisbon), key: key, now: @now)

    assert Channel.stats(state2) == %{spoofed_payload: 1}
    # no last-known fix was recorded from the forged geometry
    assert state2.last_known == %{}
  end

  test "signed claims without sensor fields do not bind (backward-compatible)", %{key: key, state: state} do
    claims = device_claims() |> Map.delete("gps")
    token = Key.sign(claims, key)
    {{:ok, _}, _} = Channel.ingest(state, event(token: token), key: key, now: @now)
  end

  # --- test-local crypto helpers ---

  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

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
      _ -> bin
    end
  end

end
