defmodule AshA2A.Attestation.GateGrantAllowlist do
  @moduledoc """
  Enforcement-side consumer for approved geofence exception grants.

  Closes the X4 membrane gap: the grant exists on the xaas approval side only
  (`Xaas.Governance.ApprovalGeofenceExceptionGrant`) and never changed an
  enforcement outcome. An in-scope, unexpired grant overrides the gate's
  `{:refused, :gps_impossible_jump}` for jumping pairs fully inside the
  granted area; everything else still refuses.

  ## Hand-pinned xaas grant fields (no-cross-repo-import law)

  Entry shape mirrors `/Users/sac/xaas/lib/xaas/governance/approval_geofence_exception_grant.ex`
  attributes (`id`, `org_id`, `identifier_or_cidr`, `ttl_hours`). xaas is
  never imported; the fields are re-pinned by hand and any drift is a
  register row, not an import.

  Two fields are enforcement-side projections recorded at approve time:

  - `approved_at` — unix seconds when the maker-checker `:approve` landed
    (xaas stores `ttl_hours` with no anchor timestamp, so expiry is
    `approved_at + ttl_hours * 3600`).
  - `area` — `%{"lat" =>, "lon" =>, "radius_km" =>}` geo projection of the
    approved exception area (the gate's scope is coordinates, xaas's is
    `identifier_or_cidr`; the projection is recorded on the approval).
  """

  @typedoc "Grant-shaped map, hand-pinned per the moduledoc."
  @type area :: %{binary() => number()}
  @type grant :: %{
          required(:grant_id) => binary(),
          required(:org_id) => binary(),
          required(:identifier_or_cidr) => binary(),
          required(:ttl_hours) => integer(),
          required(:approved_at) => integer(),
          required(:area) => area()
        }

  @doc """
  `:ok` when every impossible-jump pair in `observations` falls inside at
  least one unexpired grant's area; `{:refused, :gps_impossible_jump}`
  otherwise (expired, out-of-area, or empty allowlist).
  """
  @spec override?(list(map()), [grant()], pos_integer()) :: :ok | {:refused, :gps_impossible_jump}
  def override?(observations, grants, now) when is_list(grants) do
    live = Enum.filter(grants, &active?(&1, now))
    jumping = jumping_pairs(observations)

    if jumping != [] and Enum.all?(jumping, &covered?(&1, live)) do
      :ok
    else
      {:refused, :gps_impossible_jump}
    end
  end

  @spec active?(grant(), pos_integer()) :: boolean()
  defp active?(%{ttl_hours: ttl, approved_at: approved_at}, now)
       when is_integer(ttl) and ttl >= 0 and is_integer(approved_at) do
    now < approved_at + ttl * 3600
  end

  defp active?(_, _), do: false

  defp jumping_pairs(observations) do
    observations
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] ->
      dt = b["timestamp"] - a["timestamp"]
      dt <= 60 and AshA2A.Attestation.Gate.pair_distance_km(a, b) > 500.0
    end)
  end

  defp covered?([a, b], live) do
    Enum.any?(live, fn %{area: area} ->
      in_area?(a, area) and in_area?(b, area)
    end)
  end

  defp in_area?(%{"lat" => lat, "lon" => lon}, %{
         "lat" => c_lat,
         "lon" => c_lon,
         "radius_km" => radius_km
       })
       when is_number(lat) and is_number(lon) and is_number(radius_km) and radius_km >= 0 do
    AshA2A.Attestation.Gate.pair_distance_km(%{"lat" => lat, "lon" => lon}, %{
      "lat" => c_lat,
      "lon" => c_lon
    }) <= radius_km
  end

  defp in_area?(_, _), do: false
end
