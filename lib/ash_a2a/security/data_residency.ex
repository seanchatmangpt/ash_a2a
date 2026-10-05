# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DataResidency do
  @moduledoc """
  Data-residency admission for workloads (PRD FR-02.3): a workload tagged
  with a data-jurisdiction requirement is refused on any node whose region
  is outside the declared region (or region group).

  A task in scope for GDPR-style data locality carries a
  `data_jurisdiction` tag. This module is the dispatch-time gate: it
  compares the tag against the node's region and fails closed.

  ## Tag source and precedence (highest first)

  1. `opts[:data_jurisdiction]` — explicit caller override (used by hosts
     whose transport injects the tag at admission time);
  2. `workload["data_jurisdiction"]` or `workload[:data_jurisdiction]`
     (top-level key, string or atom form);
  3. `workload.metadata["data_jurisdiction"]` (or atom-form metadata and
     key) — the PRD naming (`metadata.data_jurisdiction`);
  4. none of the above — the workload is untagged and always passes.

  A present-but-empty tag (`nil`, `""`, whitespace-only) is untagged.

  ## Node region resolution and precedence (highest first)

  1. `opts[:node_region]` — explicit caller override;
  2. `config :ash_a2a, :node_region_provider` — a module implementing the
     `AshA2A.Security.DataResidency` behaviour (`region/0` returning
     `{:ok, binary}` or `{:error, term}`), for hosts that source region
     from cloud node metadata (e.g. GCE metadata server, ECS container
     metadata);
  3. `config :ash_a2a, :node_region` — a static region string;
  4. none — node region is UNKNOWN. **Fail closed**: a residency-tagged
     workload on a node of unknown region is refused, never passed.

  ## Region groups

  A tag naming a group (e.g. `"EU"`) matches any member region. The
  default mapping uses documented prefix rules over the public provider
  region lists, so both AWS-style (`eu-central-1`, `eu-west-1` —
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html)
  and GCP-style (`europe-west1`, `europe-north1` —
  https://cloud.google.com/about/locations) member names match:

    * `"EU"` — region normalizes to prefix `eu-` or `europe-` (AWS `eu-*`:
      eu-central-1/2, eu-west-1/2/3, eu-north-1, eu-south-1/2; GCP
      `europe-*`: europe-west1..12, europe-north1, europe-central2,
      europe-southwest1);
    * `"US"` / `"USA"` — prefix `us-` (AWS `us-east-*`/`us-west-*`; GCP
      `us-central1`, `us-east1`, `us-west1`, `us-south1`);
    * `"APAC"` — prefix `ap-` or `asia-` (AWS `ap-*`; GCP `asia-*`).

  Defaults are extendable per call via `opts[:region_groups]` (a map of
  group name to list of member regions or `prefix*` patterns, merged over
  the defaults).

  Comparison is case-insensitive throughout (both tag and region are
  normalized before compare).
  """

  @callback region() :: {:ok, String.t()} | {:error, term()}

  @type workload :: map()
  @type refusal_code ::
          :refused_data_residency_violation | :refused_data_residency_unknown_region
  @type refusal :: {:error, refusal_code(), String.t()}

  @type pass_info :: %{
          decision: :pass,
          node_region: String.t() | nil,
          data_jurisdiction: String.t() | nil,
          matched_via: :exact | :group | :untagged,
          group: String.t() | nil
        }

  @type receipt :: %{
          code: atom(),
          decision: :pass | :refused,
          detail: String.t(),
          data_jurisdiction: String.t() | nil,
          node_region: String.t() | nil,
          decided_at: DateTime.t(),
          module: module()
        }

  @default_groups %{
    "EU" => ["eu-*", "europe-*"],
    "US" => ["us-*"],
    "USA" => ["us-*"],
    "APAC" => ["ap-*", "asia-*"]
  }

  @doc """
  Admits `workload` for dispatch on this node, or refuses with a typed
  refusal `{:error, code, detail}`:

    * untagged workload — pass (`matched_via: :untagged`);
    * tagged, node region matches the tag exactly (case-insensitive) —
      pass (`matched_via: :exact`);
    * tagged, node region is a member of the tag's region group — pass
      (`matched_via: :group`);
    * tagged, node region outside the tag — refusal
      `:refused_data_residency_violation` (PRD
      `REFUSED_DATA_RESIDENCY_VIOLATION`);
    * tagged, node region UNKNOWN — fail-closed refusal
      `:refused_data_residency_unknown_region`.
  """
  @spec admit(workload(), keyword()) :: {:ok, pass_info()} | refusal()
  def admit(workload, opts \\ []) do
    case jurisdiction(workload, opts) do
      nil ->
        {:ok,
         %{
           decision: :pass,
           node_region: nil,
           data_jurisdiction: nil,
           matched_via: :untagged,
           group: nil
         }}

      tag ->
        case node_region(opts) do
          {:ok, region} ->
            decide(tag, region, opts)

          :error ->
            {:error, :refused_data_residency_unknown_region,
             "residency-tagged workload (data_jurisdiction=#{inspect(tag)}) on node of unknown region; refusing fail-closed"}
        end
    end
  end

  @doc """
  Builds a decision receipt for `workload` under the same `opts` given to
  `admit/2`. Every decision carries one (violating and fail-closed
  refusals are the forms a court replays); `code` names the outcome,
  `decision` is `:pass` or `:refused`.
  """
  @spec receipt(workload(), keyword()) :: receipt()
  def receipt(workload, opts \\ []) do
    tag = jurisdiction(workload, opts)

    {code, region} =
      case {tag, node_region(opts)} do
        {nil, _} ->
          {:passed_untagged, nil}

        {tag, {:ok, region}} ->
          case decide(tag, region, opts) do
            {:ok, _} -> {:passed, region}
            {:error, code, _detail} -> {code, region}
          end

        {_tag, :error} ->
          {:refused_data_residency_unknown_region, nil}
      end

    detail =
      case code do
        :refused_data_residency_unknown_region ->
          "residency-tagged workload (data_jurisdiction=#{inspect(tag)}) on node of unknown region; refusing fail-closed"

        :refused_data_residency_violation ->
          "node region #{inspect(region)} is outside declared data_jurisdiction #{inspect(tag)}"

        :passed ->
          "node region #{inspect(region)} satisfies data_jurisdiction #{inspect(tag)}"

        :passed_untagged ->
          "workload is not residency-tagged; no residency gate applies"
      end

    %{
      code: code,
      decision: refusal?(code),
      detail: detail,
      data_jurisdiction: tag,
      node_region: region,
      decided_at: DateTime.utc_now(),
      module: __MODULE__
    }
  end

  @doc """
  The effective tag source used by `admit/2` — exported so a court can
  pin which precedence level produced the tag under test.
  """
  @spec jurisdiction(workload(), keyword()) :: String.t() | nil
  def jurisdiction(workload, opts) when is_map(workload) do
    opts[:data_jurisdiction] ||
      fetch_tag(workload) ||
      fetch_metadata_tag(workload) ||
      nil
  end

  def jurisdiction(_workload, _opts), do: nil

  # --- internals ---

  defp fetch_tag(workload) do
    normalize(workload["data_jurisdiction"] || workload[:data_jurisdiction])
  end

  defp fetch_metadata_tag(workload) do
    metadata = workload["metadata"] || workload[:metadata] || %{}

    metadata =
      case metadata do
        m when is_map(m) -> m
        _ -> %{}
      end

    normalize(metadata["data_jurisdiction"] || metadata[:data_jurisdiction])
  end

  defp normalize(nil), do: nil

  defp normalize(tag) do
    case to_string(tag) |> String.trim() do
      "" -> nil
      tag -> tag
    end
  rescue
    _ -> nil
  end

  defp node_region(opts) do
    region_from(opts[:node_region]) ||
      provider_region() ||
      region_from(Application.get_env(:ash_a2a, :node_region)) ||
      :error
  end

  defp region_from(nil), do: nil

  defp region_from(region) when is_binary(region) do
    case String.trim(region) do
      "" -> nil
      region -> {:ok, region}
    end
  end

  defp region_from(_), do: nil

  defp provider_region do
    case Application.get_env(:ash_a2a, :node_region_provider) do
      nil ->
        nil

      mod when is_atom(mod) ->
        case mod.region() do
          {:ok, region} -> region_from(region)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp decide(tag, region, opts) do
    groups = merged_groups(opts)

    cond do
      String.downcase(tag) == String.downcase(region) ->
        {:ok,
         %{
           decision: :pass,
           node_region: region,
           data_jurisdiction: tag,
           matched_via: :exact,
           group: nil
         }}

      true ->
        case group_match(tag, region, groups) do
          {group_name, true} ->
            {:ok,
             %{
               decision: :pass,
               node_region: region,
               data_jurisdiction: tag,
               matched_via: :group,
               group: group_name
             }}

          _ ->
            {:error, :refused_data_residency_violation,
             "node region #{inspect(region)} is outside declared data_jurisdiction #{inspect(tag)}"}
        end
    end
  end

  defp merged_groups(opts) do
    case Keyword.get(opts, :region_groups) do
      nil -> @default_groups
      extra when is_map(extra) -> Map.merge(@default_groups, extra)
      _ -> @default_groups
    end
  end

  defp group_match(tag, region, groups) do
    tag_n = String.downcase(tag)

    case Enum.find(groups, fn {name, _} -> String.downcase(name) == tag_n end) do
      {name, members} when is_list(members) ->
        {name, Enum.any?(members, &member_match?(&1, String.downcase(region)))}

      _ ->
        :no_match
    end
  end

  # Default group members are prefix patterns over the public provider
  # region lists cited in the moduledoc. A member ending in `*` is a
  # prefix rule ("eu-*" admits "eu-west-1"); any other member is an exact
  # region name.
  defp member_match?(pattern, region) when is_binary(pattern) and is_binary(region) do
    if String.ends_with?(pattern, "*") do
      region |> String.downcase() |> String.starts_with?(pattern |> String.trim_trailing("*") |> String.downcase())
    else
      String.downcase(pattern) == String.downcase(region)
    end
  end

  defp member_match?(_, _), do: false

  defp refusal?(code) when is_atom(code),
    do: if(String.starts_with?(Atom.to_string(code), "refused"), do: :refused, else: :pass)
end
