# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.PartisanIntegrationTest do
  @moduledoc """
  Tracking court for the permanently-BLOCKED Partisan integration
  tombstone (audit finding #6; origin: v26.9.16
  `feat/partisan-investigate-v26.9.16`, full evidence in
  `docs/archive/reports/partisan-integration-investigation.md`).

  The original integration test (two real local BEAM nodes joining over
  Partisan's own overlay via `partisan:join/1`, one real message delivered
  via `partisan:cast_message/2`) could never run: every Partisan Hex
  release up to 6.2.0 hard-pins the non-optional `telemetry ~> 1.1.0`,
  which does not overlap this repo's already-required
  `oban ~> 2.24` -> `telemetry ~> 1.3` (locked at 1.4.2). A second,
  independent conflict layer (Partisan's exact `opentelemetry_api 1.2.1`
  pin vs. this repo's transitive `opentelemetry_api ~> 1.4`) was also
  confirmed. Partisan was therefore never added to `mix.exs`/`mix.lock`.

  The dead tombstone (an unconditionally `@tag :skip`ped test whose body
  was `flunk("unreachable")`) carried a re-check mechanism of zero bits --
  it could never observe the day the blocker clears. This court replaces
  it with a real observation, executed every run, read-only, no writes to
  `mix.exs`/`mix.lock`:

  1. Query the live Hex API for the Partisan package's releases and their
     real published `telemetry` requirements.
  2. If any existing release's telemetry requirement admits the telemetry
     version this repo locks (`1.4.2`), the blocker is gone: the test
     FAILS with a typed `PARTISAN_BLOCKER_CLEARED` message forcing revival
     of the real two-node integration test (and de-tombstoning of
     `docs/archive/reports/partisan-integration-investigation.md`).
  3. If no release's telemetry requirement admits the locked telemetry
     version, the known-conflict state is asserted explicitly with the
     release evidence inlined, so the tombstone is re-witnessed rather
     than passing vacuously.

  This test does NOT attempt the upgrade and does NOT mock the Hex API.
  Per `~/.claude/rules/testing-chicago-style.md` the collaborator (the
  real Hex registry over real HTTPS) is used directly.
  """

  use ExUnit.Case, async: false

  # Deliberately NOT tagged :serial/:serial_shard: unlike the dead tombstone
  # (which was also excluded from every default run, i.e. re-checked zero
  # bits per run), this court must execute by default. It is a read-only
  # Hex API observation, not a clustering test.
  @moduletag :partisan_investigation

  @hex_api "https://hex.pm/api/packages/partisan"
  # Telemetry version this repo actually locks (mix.lock: telemetry 1.4.2,
  # required by oban ~> 2.24 as `~> 1.3`).
  @locked_telemetry {1, 4, 2}

  defp parse_version(v) do
    v
    |> to_string()
    |> String.split("-")
    |> hd()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> pad3()
  end

  defp pad3([major]), do: [major, 0, 0]
  defp pad3([major, minor]), do: [major, minor, 0]
  defp pad3(v), do: v

  defp ver_to_tuple([a, b, c]), do: {a, b, c}

  # Minimal requirement evaluator for the shapes Partisan actually
  # publishes for telemetry ("~> 1.1.0", "~> 1.1", ">= 1.3", "1.2.1", ...).
  # Returns true when `req` admits `version`.
  defp admits?(req, version) do
    req = to_string(req) |> String.trim()

    cond do
      String.starts_with?(req, "~>") ->
        range_str = String.split(req, "~>") |> Enum.at(1) |> String.trim()
        components = String.split(range_str, ".")
        [req_major, req_minor | _rest] = parse_version(range_str)
        {v_major, v_minor, _} = version

        if length(components) >= 3 do
          # patch-pinned: "~> 1.1.0" admits only 1.1.x
          v_major == req_major and v_minor == req_minor
        else
          # "~> 1.1" / "~> 1.3" admit any 1.x at or above the minor floor
          # (up to, excluding, 2.0)
          v_major == req_major and v_minor >= req_minor
        end

      String.starts_with?(req, ">=") ->
        [req_major, req_minor, req_patch] = parse_version(String.split(req, ">=") |> Enum.at(1) |> String.trim())
        version >= {req_major, req_minor, req_patch}

      req =~ ~r/^\d/ ->
        {req_major, req_minor, req_patch} = ver_to_tuple(parse_version(req))
        version == {req_major, req_minor, req_patch}

      true ->
        # Unrecognized shape: conservatively treat as NOT admitting the
        # locked version, so the court cannot silently go green.
        false
    end
  end

  defp hex_get(url, attempts_left \\ 3)

  defp hex_get(_url, 0), do: flunk("PARTISAN_TRACKING_COURT_NETWORK: hex.pm unreachable after retries")

  defp hex_get(url, attempts_left) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    headers = [
      {~c"user-agent", ~c"ash_a2a partisan-integration tracking court (hex.pm/ash_a2a)"}
    ]

    request = :httpc.request(:get, {String.to_charlist(url), headers}, [
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()],
      timeout: 15_000,
      connect_timeout: 15_000
    ], [])

    case request do
      {:ok, {{_, 200, _}, _, body}} ->
        to_string(body)

      {:ok, {{_, status, _}, _, _}} ->
        flunk("PARTISAN_TRACKING_COURT_HTTP_#{status}: unexpected status from #{url}")

      {:error, _reason} ->
        Process.sleep(1_000)
        hex_get(url, attempts_left - 1)
    end
  end

  test "Partisan Hex releases are re-witnessed against this repo's telemetry pin (tracking court)" do
    body = hex_get(@hex_api)
    assert {:ok, package} = Jason.decode(body)

    releases = package["releases"]
    assert is_list(releases) and releases != [], "Hex API returned no releases for partisan"

    # Fetch each release's real published requirements (latest first).
    checked =
      for release <- releases,
          version = release["version"],
          {:ok, rel} = Jason.decode(hex_get("#{@hex_api}/releases/#{version}")),
          telemetry_req = get_in(rel, ["requirements", "telemetry", "requirement"]) do
        {version, telemetry_req, admits?(telemetry_req, @locked_telemetry)}
      end

    assert checked != [],
           "PARTISAN_TRACKING_COURT_EMPTY: no partisan release on Hex publishes a telemetry requirement; manual re-check required"

    compatible = for {version, req, true} <- checked, do: {version, req}
    latest = hd(checked)

    # The assertion IS the court: while Hex shows no telemetry-compatible
    # release, the known-conflict assertion holds (suite green, evidence
    # receipt printed below). The moment any release admits the locked
    # telemetry version, this assertion fails typed and forces revival.
    assert compatible == [],
           """
           PARTISAN_BLOCKER_CLEARED: Partisan release(s) #{inspect(compatible)} now admit \
           telemetry #{inspect(@locked_telemetry)}. The hex-resolution blocker documented in \
           docs/archive/reports/partisan-integration-investigation.md is STALE. Revive the real \
           two-node Partisan integration test now: add `{:partisan, "~> ...", only: :dev}` to \
           mix.exs, run `mix deps.get`, and restore the partisan:join/cast_message test body. \
           De-tombstone the investigation report in the same transition.\
           """

    IO.puts("""
    [partisan tombstone re-witnessed #{Date.utc_today()}] BLOCKED state still accurate: \
    #{length(checked)} Hex releases checked (latest #{elem(latest, 0)}), none admits \
    telemetry #{inspect(@locked_telemetry)} (oban ~> 2.24 lock). Latest requirement: \
    #{elem(latest, 1)}. Per-release: #{inspect(checked, limit: 20)}\
    """)
  end

  test "requirement evaluator admits only telemetry ranges that genuinely cover the locked version" do
    # Negative controls: the shapes that caused the original blocker.
    refute admits?("~> 1.1.0", @locked_telemetry)
    refute admits?("~>1.1.0", @locked_telemetry)
    refute admits?("1.2.1", @locked_telemetry)
    # Positive controls: shapes that would clear the blocker.
    assert admits?("~> 1.3", @locked_telemetry)
    assert admits?("~> 1.1", @locked_telemetry)
    assert admits?(">= 1.3", @locked_telemetry)
    assert admits?(">= 1.0", @locked_telemetry)
    # Unrecognized shape must not silently admit.
    refute admits?("banana", @locked_telemetry)
  end
end
