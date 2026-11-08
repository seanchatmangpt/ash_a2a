defmodule AshA2A.Attestation.Gate do
  @moduledoc """
  Article-10 ingress attestation gate: crypto + claim-consistency validation.

  ## Threat model (honest scope)

  This gate validates **crypto and claim consistency only**. It verifies:

  - the ECDSA P-256 signature over the nonce + device claims,
  - timestamp freshness of the attestation payload,
  - internal consistency of device/sensor claims (emulator markers,
    GPS/sensor metadata sanity, physically-possible movement).

  It does **NOT** perform true hardware-enclave attestation. Real Play
  Integrity (Android) / App Attest / DeviceCheck (iOS) verification requires
  the mobile client's server-side integration with Google/Apple services,
  where the device proves possession of a hardware-backed key to the OS
  vendor. This module verifies the claims' signature, freshness, and
  consistency, and therefore **trusts the signing key holder** (whatever
  service holds `priv`). A compromised or colluding attestation service, or
  an emulator that spoofs its claims *and* obtains a signature from a real
  key holder, will pass. **Never claim this module detects all emulators** —
  it detects only emulators that declare themselves honestly via claims.
  """

  alias AshA2A.Attestation.GateGrantAllowlist
  alias AshA2A.Attestation.Key

  @default_max_staleness_sec 90
  # Forward clock skew acceptance window (seconds). A device clock up to 5s
  # ahead of the server is ACCEPTED (NTP drift on mobile is real); anything
  # further in the future is refused as `:clock_skew`. Deliberate trade-off:
  # tightening below 5s would reject honest devices with modest drift, while
  # a >5s-future timestamp buys an attacker only a 5s head start on replay —
  # and replay is independently closed by per-coordinator nonce tracking in
  # `AshA2A.Ingress.Channel`.
  @max_future_skew_sec 5
  # Haversine great-circle distance; ~500 km within one minute is not
  # achievable by any real transport.
  @max_jump_km 500.0
  # GPS accuracy sane bounds: 0 < accuracy <= 100_000 meters (100 km).
  @max_accuracy_m 100_000.0

  @emulator_packages [
    "com.google.android.launcher.layouts.genymotion",
    "com.bluestacks",
    "com.bignox.app",
    "com.vphone.mumu",
    "com.ldmnq",
    "com.android.fly SiliconFlowEmulator"
  ]

  @type refused :: {:refused, :bad_signature | :emulator_detected | :stale | :spoofed_payload | :gps_impossible_jump | :malformed_token}

  @doc """
  Verifies `{device_token, nonce}`: signature over nonce + device claims,
  then emulator detection.

  Returns `{:ok, claims}` or a typed `{:refused, reason}`.
  """
  @spec verify_enclave({binary(), binary()}, Key.key() | Keyword.t()) :: {:ok, map()} | refused()
  def verify_enclave({device_token, nonce}, key_or_opts) do
    key =
      case key_or_opts do
        %{} = k when is_map_key(k, :pub) -> k
        opts when is_list(opts) -> Keyword.get(opts, :key)
      end

    with {:ok, claims} <- Key.verify(device_token, key),
         true <- claims_match_nonce?(claims, nonce) do
      detect_emulator(claims)
    else
      {:refused, _} = refused -> refused
      {:error, reason} -> {:refused, reason}
      false -> {:refused, :nonce_mismatch}
      {:ok, _} -> {:refused, :nonce_mismatch}
    end
  end

  @doc """
  Freshness check: `claims["issued_at"]` (unix seconds) must be within
  `max_staleness_sec` (option, default #{@default_max_staleness_sec}) of `now`
  (option, default `System.system_time(:second)`).

  Returns `:ok`, `{:refused, :stale}` (too old) or `{:refused, :clock_skew}`
  (more than #{@max_future_skew_sec}s in the future). Up to
  #{@max_future_skew_sec}s of forward skew is accepted for real device clock
  drift.
  """
  @spec verify_freshness(map(), Keyword.t()) :: :ok | {:refused, :stale | :clock_skew | :malformed_token}
  def verify_freshness(claims, opts \\ []) when is_map(claims) do
    max_age = Keyword.get(opts, :max_staleness_sec, @default_max_staleness_sec)
    now = Keyword.get(opts, :now, System.system_time(:second))

    case claims do
      %{"issued_at" => issued_at} when is_integer(issued_at) and issued_at > now + @max_future_skew_sec ->
        {:refused, :clock_skew}

      %{"issued_at" => issued_at} when is_integer(issued_at) ->
        if now - issued_at <= max_age do
          :ok
        else
          {:refused, :stale}
        end

      _ ->
        {:refused, :malformed_token}
    end
  end

  @doc """
  Sensor/EXIF-ish metadata validation: requires `camera_make`, `camera_model`,
  a GPS block with a fresh `timestamp`, and a sane `accuracy`.

  Returns `:ok` or `{:refused, :spoofed_payload}`.
  """
  @spec verify_sensor_metadata(map(), Keyword.t()) :: :ok | {:refused, :spoofed_payload | :stale | :clock_skew}
  def verify_sensor_metadata(claims, opts \\ []) when is_map(claims) do
    max_age = Keyword.get(opts, :max_staleness_sec, @default_max_staleness_sec)
    now = Keyword.get(opts, :now, System.system_time(:second))

    gps = claims["gps"]

    cond do
      not valid_camera?(claims) ->
        {:refused, :spoofed_payload}

      not valid_gps?(gps) ->
        {:refused, :spoofed_payload}

      not (is_integer(gps["timestamp"]) and gps["timestamp"] <= now + @max_future_skew_sec) ->
        {:refused, :clock_skew}

      now - gps["timestamp"] > max_age ->
        {:refused, :stale}

      true ->
        :ok
    end
  end

  defp valid_camera?(%{"camera_make" => make, "camera_model" => model})
       when is_binary(make) and make != "" and is_binary(model) and model != "",
       do: true

  defp valid_camera?(_), do: false

  # Finite-float law: NaN fails `x == x`; out-of-range/infinite values fail
  # the range bounds. Anything non-finite must never reach :math (a NaN
  # latitude propagates through the haversine and `:math.sqrt/1` on a
  # negative intermediate raises badarg — a crash, not a typed refusal).
  defp valid_gps?(
         %{"accuracy" => accuracy, "lat" => lat, "lon" => lon}
       )
       when is_number(accuracy) and accuracy > 0 and accuracy <= @max_accuracy_m and
              is_number(lat) and lat >= -90 and lat <= 90 and lat == lat and
              is_number(lon) and lon >= -180 and lon <= 180 and lon == lon,
       do: true

  defp valid_gps?(_), do: false

  @doc """
  Mock-GPS rejection: `observations` is a list of `%{"lat" =>, "lon" =>,
  "timestamp" =>}` (unix seconds), sorted ascending. More than
  #{@max_jump_km} km between consecutive observations whose timestamps are
  within 60 seconds yields `{:refused, :gps_impossible_jump}`; otherwise `:ok`.
  """
  @spec verify_gps_trajectory(list(map())) :: :ok | {:refused, :gps_impossible_jump | :spoofed_payload}
  def verify_gps_trajectory(observations) when is_list(observations) do
    verify_gps_trajectory(observations, [])
  end

  @doc """
  `verify_gps_trajectory/1` with an approved-grant allowlist (option
  `:approved_grants`, shaped by `AshA2A.Attestation.GateGrantAllowlist`;
  `:now` overridable for tests). An in-scope, unexpired grant overrides a
  `:gps_impossible_jump` refusal to `:ok`; with no grants supplied the
  outcome is identical to `/1`.
  """
  @spec verify_gps_trajectory(list(map()), Keyword.t()) ::
          :ok | {:refused, :gps_impossible_jump | :spoofed_payload}
  def verify_gps_trajectory(observations, opts) when is_list(observations) and is_list(opts) do
    case verify_gps_trajectory_base(observations) do
      {:refused, :gps_impossible_jump} = refused ->
        now = Keyword.get(opts, :now, System.system_time(:second))
        grants = Keyword.get(opts, :approved_grants, [])

        case GateGrantAllowlist.override?(observations, grants, now) do
          :ok -> :ok
          _ -> refused
        end

      other ->
        other
    end
  end

  defp verify_gps_trajectory_base(observations) do
    with :ok <- all_finite_obs?(observations) do
      obs = Enum.sort_by(observations, & &1["timestamp"])

      obs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce_while(:ok, fn [a, b], :ok ->
        dt = b["timestamp"] - a["timestamp"]
        dist_km = haversine_km(a, b)

        cond do
          not (is_number(dt) and dt >= 0) ->
            {:halt, {:refused, :spoofed_payload}}

          dist_km == :error ->
            # :math crashed on adversarial coordinates despite guards —
            # refuse instead of crashing the caller.
            {:halt, {:refused, :spoofed_payload}}

          dt <= 60 and dist_km > @max_jump_km ->
            {:halt, {:refused, :gps_impossible_jump}}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end

  # Identical-coordinate pairs (the "no-movement bypass": an attacker repeats
  # the exact same fix forever) are physically lawful — distance 0 — and are
  # NOT refused here; the attack they enable (token replay) is closed by
  # per-coordinator nonce tracking in `AshA2A.Ingress.Channel`, not by
  # geometry. What IS refused here: non-finite or non-numeric coordinates
  # (they would crash :math), and future-stamped observations beyond skew.
  defp all_finite_obs?(observations) do
    Enum.reduce_while(observations, :ok, fn
      %{"lat" => lat, "lon" => lon, "timestamp" => ts}, :ok
      when is_number(lat) and lat == lat and is_number(lon) and lon == lon and is_integer(ts) ->
        if ts > 0 do
          {:cont, :ok}
        else
          {:halt, {:refused, :spoofed_payload}}
        end

      _obs, :ok ->
        {:halt, {:refused, :spoofed_payload}}
    end)
  end

  # --- internals ---

  defp claims_match_nonce?(%{"nonce" => nonce}, nonce) when is_binary(nonce), do: true
  defp claims_match_nonce?(_, _), do: false

  defp detect_emulator(claims) do
    fingerprint = claims["os_fingerprint"] || ""
    packages = claims["installed_packages"] || []

    virtual? = claims["is_virtual"] == true
    fingerprint_hit? = fingerprint =~ ~r/(emulator|generic|sdk_gphone|vbox|qemu)/i
    package_hit? = Enum.any?(packages, fn pkg -> emulator_package?(pkg) end)

    if virtual? or fingerprint_hit? or package_hit? do
      {:refused, :emulator_detected}
    else
      {:ok, claims}
    end
  end

  defp emulator_package?(pkg) when is_binary(pkg) do
    Enum.any?(@emulator_packages, fn emu -> String.contains?(String.downcase(pkg), prefix_of(emu)) end)
  end

  defp emulator_package?(_), do: false

  defp prefix_of(emu), do: emu |> String.downcase() |> String.split(" ") |> List.first()

  # Belt-and-suspenders: even with finite-input guards above, an adversarial
  # huge integer (e.g. lat as a 10^400 integer) can still raise badarg inside
  # :math. Never crash on attacker input — degrade to :error, refused upstream.
  defp haversine_km(a, b) do
    compute_haversine_km(a, b)
  rescue
    _ -> :error
  end

  @doc false
  @spec pair_distance_km(map(), map()) :: float() | :inf
  def pair_distance_km(a, b) do
    case haversine_km(a, b) do
      :error -> :inf
      km -> km
    end
  end

  defp compute_haversine_km(%{"lat" => lat1, "lon" => lon1}, %{"lat" => lat2, "lon" => lon2}) do
    r = 6371.0
    dlat = :math.pi * (lat2 - lat1) / 180
    dlon = :math.pi * (lon2 - lon1) / 180
    lat1r = :math.pi * lat1 / 180
    lat2r = :math.pi * lat2 / 180

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1r) * :math.cos(lat2r) * :math.sin(dlon / 2) * :math.sin(dlon / 2)

    2 * r * :math.asin(:math.sqrt(min(1, a)))
  end
end
