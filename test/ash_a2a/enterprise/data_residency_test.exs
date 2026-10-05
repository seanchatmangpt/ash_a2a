# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.DataResidencyTest do
  use ExUnit.Case, async: false

  alias AshA2A.Security.DataResidency

  @moduledoc """
  FR-02.3 data-residency acceptance court (PRD §6.2).

  Cross-region dispatches fail closed with the typed
  `:refused_data_residency_violation` (PRD `REFUSED_DATA_RESIDENCY_VIOLATION`)
  and zero downstream execution. The PII/PHI-never-persisted-in-plaintext
  half of FR-02 is court-pinned separately by
  `test/ash_a2a/enterprise/dlp_filter_test.exs` ("raw store scan: redacted
  payload persists with zero plaintext bytes") and is cited here, not
  duplicated.
  """

  # A real provider implementation (Chicago: a hand-written real interface
  # implementation is not a mock) standing in for a cloud node-metadata
  # source. Region is configurable via :persistent_term so each court sets
  # the observed world it exercises.
  defmodule StaticRegionProvider do
    @behaviour AshA2A.Security.DataResidency
    @key {__MODULE__, :region}

    def put(region), do: :persistent_term.put(@key, region)
    @spec region() :: {:ok, String.t()} | {:error, :unset}
    def region, do: :persistent_term.get(@key, {:error, :unset})
  end

  setup do
    original_env = Application.get_env(:ash_a2a, :node_region)
    original_provider = Application.get_env(:ash_a2a, :node_region_provider)
    StaticRegionProvider.put({:error, :unset})

    on_exit(fn ->
      restore(:node_region, original_env)
      restore(:node_region_provider, original_provider)
      StaticRegionProvider.put({:error, :unset})
    end)

    :ok
  end

  defp restore(:node_region, nil), do: Application.delete_env(:ash_a2a, :node_region)
  defp restore(:node_region, value), do: Application.put_env(:ash_a2a, :node_region, value)

  defp restore(:node_region_provider, nil),
    do: Application.delete_env(:ash_a2a, :node_region_provider)

  defp restore(:node_region_provider, value),
    do: Application.put_env(:ash_a2a, :node_region_provider, value)

  # --- court 1: matching region passes (exact) ---

  test "tagged workload passes when node region matches the tag exactly" do
    Application.put_env(:ash_a2a, :node_region, "eu-central-1")

    assert {:ok, info} =
             DataResidency.admit(%{"metadata" => %{"data_jurisdiction" => "eu-central-1"}})

    assert info.matched_via == :exact
    assert info.decision == :pass
  end

  # --- court 2: violating region -> typed refusal + receipt ---

  test "tagged workload on a region outside the tag is refused with the typed code" do
    Application.put_env(:ash_a2a, :node_region, "us-east-1")

    assert {:error, :refused_data_residency_violation, detail} =
             DataResidency.admit(%{"metadata" => %{"data_jurisdiction" => "eu-central-1"}})

    assert detail =~ "us-east-1"

    receipt = DataResidency.receipt(%{"metadata" => %{"data_jurisdiction" => "eu-central-1"}})

    assert receipt.code == :refused_data_residency_violation
    assert receipt.decision == :refused
    assert receipt.node_region == "us-east-1"
    assert receipt.data_jurisdiction == "eu-central-1"
    assert %DateTime{} = receipt.decided_at
    assert receipt.module == DataResidency
  end

  # --- court 3: missing region info on a tagged workload fails closed ---

  test "tagged workload on a node of unknown region is refused (fail closed)" do
    Application.delete_env(:ash_a2a, :node_region)

    assert {:error, :refused_data_residency_unknown_region, detail} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})

    assert detail =~ "fail-closed"

    # Same refusal when the configured region is an empty string.
    Application.put_env(:ash_a2a, :node_region, "  ")

    assert {:error, :refused_data_residency_unknown_region, _} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end

  # --- court 4: untagged workload passes ---

  test "untagged workload passes without region resolution" do
    Application.delete_env(:ash_a2a, :node_region)

    assert {:ok, %{decision: :pass, matched_via: :untagged}} = DataResidency.admit(%{})

    assert {:ok, %{matched_via: :untagged}} = DataResidency.admit(%{"metadata" => %{"data_jurisdiction" => ""}})

    assert {:ok, %{matched_via: :untagged}} = DataResidency.admit(%{"metadata" => %{"data_jurisdiction" => "   "}})
  end

  # --- court 5: region-group mapping ---

  test "EU group matches AWS and GCP EU regions, not non-EU regions" do
    Application.put_env(:ash_a2a, :node_region, "eu-west-1")

    assert {:ok, %{matched_via: :group, group: "EU"}} =
             DataResidency.admit(%{"data_jurisdiction" => "EU"})

    # GCP-style member of the EU group (europe-west1).
    Application.put_env(:ash_a2a, :node_region, "europe-west1")

    assert {:ok, %{matched_via: :group, group: "EU"}} =
             DataResidency.admit(%{"data_jurisdiction" => "EU"})

    # eu-central-1 (the contract's example) is in-group.
    Application.put_env(:ash_a2a, :node_region, "eu-central-1")

    assert {:ok, %{matched_via: :group}} = DataResidency.admit(%{"data_jurisdiction" => "EU"})

    # A non-EU region does not match the EU group.
    Application.put_env(:ash_a2a, :node_region, "us-east-1")

    assert {:error, :refused_data_residency_violation, _} =
             DataResidency.admit(%{"data_jurisdiction" => "EU"})
  end

  test "US and APAC groups route to their member prefixes" do
    Application.put_env(:ash_a2a, :node_region, "us-central1")

    assert {:ok, %{matched_via: :group, group: "US"}} =
             DataResidency.admit(%{"data_jurisdiction" => "us"})

    Application.put_env(:ash_a2a, :node_region, "ap-southeast-2")

    assert {:ok, %{matched_via: :group, group: "APAC"}} =
             DataResidency.admit(%{"data_jurisdiction" => "APAC"})

    Application.put_env(:ash_a2a, :node_region, "asia-south1")

    assert {:ok, %{matched_via: :group, group: "APAC"}} =
             DataResidency.admit(%{"data_jurisdiction" => "APAC"})
  end

  test "region_groups opt extends the default mapping" do
    Application.put_env(:ash_a2a, :node_region, "gov-west-1")

    assert {:error, :refused_data_residency_violation, _} =
             DataResidency.admit(%{"data_jurisdiction" => "GOV"})

    assert {:ok, %{matched_via: :group, group: "GOV"}} =
             DataResidency.admit(%{"data_jurisdiction" => "GOV"},
               region_groups: %{"GOV" => ["gov-*"]}
             )
  end

  # --- court 6: provider precedence over static config ---

  test "node_region_provider takes precedence over static :node_region" do
    Application.put_env(:ash_a2a, :node_region, "us-east-1")
    Application.put_env(:ash_a2a, :node_region_provider, StaticRegionProvider)
    StaticRegionProvider.put({:ok, "eu-central-1"})

    assert {:ok, %{matched_via: :exact, node_region: "eu-central-1"}} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end

  test "provider error falls through to static :node_region" do
    Application.put_env(:ash_a2a, :node_region, "eu-central-1")
    Application.put_env(:ash_a2a, :node_region_provider, StaticRegionProvider)
    StaticRegionProvider.put({:error, :metadata_unavailable})

    assert {:ok, %{matched_via: :exact, node_region: "eu-central-1"}} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end

  test "provider without a region and no static region fails closed" do
    Application.delete_env(:ash_a2a, :node_region)
    Application.put_env(:ash_a2a, :node_region_provider, StaticRegionProvider)
    StaticRegionProvider.put({:error, :unset})

    assert {:error, :refused_data_residency_unknown_region, _} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end

  # --- court 7: tag precedence ---

  test "opts :data_jurisdiction overrides the workload metadata tag" do
    Application.put_env(:ash_a2a, :node_region, "us-east-1")

    workload = %{"metadata" => %{"data_jurisdiction" => "us-east-1"}}

    assert {:error, :refused_data_residency_violation, _} =
             DataResidency.admit(workload, data_jurisdiction: "eu-central-1")

    assert {:ok, %{matched_via: :exact}} = DataResidency.admit(workload)
  end

  test "top-level tag takes precedence over metadata tag" do
    Application.put_env(:ash_a2a, :node_region, "eu-central-1")

    workload = %{
      "data_jurisdiction" => "eu-central-1",
      "metadata" => %{"data_jurisdiction" => "us-east-1"}
    }

    assert {:ok, %{matched_via: :exact}} = DataResidency.admit(workload)
  end

  test "atom-form keys and atom-form tags are accepted" do
    Application.put_env(:ash_a2a, :node_region, "eu-central-1")

    assert {:ok, %{matched_via: :exact}} =
             DataResidency.admit(%{metadata: %{data_jurisdiction: :"eu-central-1"}})
  end

  test "case-insensitive exact match" do
    Application.put_env(:ash_a2a, :node_region, "EU-Central-1")

    assert {:ok, %{matched_via: :exact}} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end

  # --- FR-02.3 acceptance: dispatch-level fail-closed ---------------------------
  #
  # The gate above is the admission function; these courts drive the real
  # dispatch path (AshA2A.Enterprise.Pipeline residency stage) with a real
  # inner plug that writes a side-effect marker. A violating dispatch must
  # answer the typed refusal and never reach the inner plug.

  defmodule DispatchMarkerPlug do
    @moduledoc false

    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      :persistent_term.put({__MODULE__, :executed, opts[:ref]}, true)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
    end
  end

  defp dispatch(workload_params, residency_opts, ref) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => workload_params
      })

    conn =
      "/"
      |> Plug.Test.conn(:post, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    cfg =
      AshA2A.Enterprise.Pipeline.init(
        inner: {DispatchMarkerPlug, [ref: ref]},
        residency: residency_opts
      )

    executed_key = {DispatchMarkerPlug, :executed, ref}

    on_exit(fn -> :persistent_term.erase(executed_key) end)

    AshA2A.Enterprise.Pipeline.call(conn, cfg)
  end

  defp executed?(ref), do: :persistent_term.get({DispatchMarkerPlug, :executed, ref}, false)

  test "violation: tagged eu-central-1 workload dispatched on a us-east-1 node is refused with zero downstream execution" do
    ref = make_ref()

    conn =
      dispatch(%{"metadata" => %{"data_jurisdiction" => "eu-central-1"}},
        [node_region: "us-east-1"],
        ref
      )

    assert conn.status == 403
    assert %{"error" => "refused_data_residency_violation", "stage" => "residency", "detail" => detail} =
             Jason.decode!(conn.resp_body)

    assert detail =~ "us-east-1"
    assert detail =~ "eu-central-1"

    # Zero downstream execution: the inner plug's side-effect marker was
    # never written.
    refute executed?(ref)
  end

  test "matching region: dispatch proceeds through the residency stage and reaches the inner plug" do
    ref = make_ref()

    conn = dispatch(%{"metadata" => %{"data_jurisdiction" => "eu-central-1"}}, [node_region: "eu-central-1"], ref)

    assert conn.status == 200
    assert executed?(ref)
  end

  test "untagged workload: dispatch proceeds (no residency gate applies)" do
    ref = make_ref()

    conn = dispatch(%{"skill" => "converse"}, [node_region: "us-east-1"], ref)

    assert conn.status == 200
    assert executed?(ref)
  end

  test "fail closed: invalid (non-binary) region metadata refuses, never silently passes" do
    assert {:error, :refused_data_residency_unknown_region, _} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"}, node_region: 1234)

    # A provider returning a non-binary region falls through to the next
    # source; with no further source, the gate still refuses.
    Application.delete_env(:ash_a2a, :node_region)
    Application.put_env(:ash_a2a, :node_region_provider, StaticRegionProvider)
    StaticRegionProvider.put({:ok, 1234})

    assert {:error, :refused_data_residency_unknown_region, _} =
             DataResidency.admit(%{"data_jurisdiction" => "eu-central-1"})
  end
end
