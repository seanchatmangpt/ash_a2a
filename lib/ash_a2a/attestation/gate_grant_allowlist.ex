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
  @spec override?(list(map()), [grant()], integer()) :: :ok | {:refused, :gps_impossible_jump}
  def override?(observations, grants, now), do: override?(observations, grants, now, [])

  @doc """
  `override?/3` with scope options: `:org_id` and `:identifier` restrict
  grants to those whose own `:org_id` / `:identifier_or_cidr` equal the
  supplied value (only when the grant carries that field).
  """
  @spec override?(list(map()), [grant()], integer(), Keyword.t()) ::
          :ok | {:refused, :gps_impossible_jump}
  def override?(observations, grants, now, opts) when is_list(grants) and is_list(opts) do
    live = grants |> Enum.filter(&scoped?(&1, opts)) |> Enum.filter(&active?(&1, now))
    observations = sort_obs(observations)
    jumping = jumping_pairs(observations)

    if is_list(observations) and jumping != [] and Enum.all?(jumping, &covered?(&1, live)) do
      :ok
    else
      {:refused, :gps_impossible_jump}
    end
  end

  defp sort_obs(obs) when is_list(obs) do
    if Enum.all?(obs, &(is_map(&1) and is_integer(&1["timestamp"]))),
      do: Enum.sort_by(obs, & &1["timestamp"]),
      else: []
  end

  defp sort_obs(_), do: []

  defp scoped?(grant, opts) when is_map(grant) do
    field_ok?(grant, :org_id, Keyword.get(opts, :org_id)) and
      field_ok?(grant, :identifier_or_cidr, Keyword.get(opts, :identifier))
  end

  defp scoped?(_, _), do: false

  defp field_ok?(_grant, _key, nil), do: true

  defp field_ok?(grant, key, want) do
    case Map.fetch(grant, key) do
      {:ok, have} -> have == want
      :error -> true
    end
  end

  @spec active?(grant(), integer()) :: boolean()
  defp active?(%{ttl_hours: ttl, approved_at: approved_at}, now)
       when is_integer(ttl) and ttl >= 0 and is_integer(approved_at) and is_integer(now) do
    approved_at <= now and now < approved_at + ttl * 3600
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
    Enum.any?(live, fn
      %{area: area} -> in_area?(a, area) and in_area?(b, area)
      _ -> false
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
