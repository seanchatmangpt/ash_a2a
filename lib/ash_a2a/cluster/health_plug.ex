# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.HealthPlug do
  @moduledoc """
  Drain-aware `/healthz` surface for `AshA2A.Cluster.DrainManager`.

  Phase 1 (Cordon) of FR-04: once the drain manager is cordoned (SIGTERM
  received), every `GET <mount>/healthz` returns `503` with a
  `retry-after` header (default `30`) so load balancers evict the node
  while in-flight work continues. Before cordon the same path answers
  `200`. Bodies are JSON status only; any other path or method passes
  through untouched so the plug composes in a pipeline without shadowing
  routes.

  The drain manager is resolved per request from, in order: the
  `:drain_manager` plug option (a name or pid), then
  `config :ash_a2a, :cluster_drain_manager`, then the default
  `AshA2A.Cluster.DrainManager` name.
  """

  @behaviour Plug

  import Plug.Conn

  @default_retry_after_s 30

  @impl Plug
  def init(opts),
    do: Keyword.validate!(opts, [:drain_manager, retry_after_s: @default_retry_after_s])

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, opts) do
    drain_manager = Keyword.get(opts, :drain_manager) || default_drain_manager()
    retry_after_s = Keyword.fetch!(opts, :retry_after_s)

    if drain_cordoned?(drain_manager) do
      payload = %{
        "status" => "draining",
        "detail" => "node cordoned for drain; retry elsewhere"
      }

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
      |> send_resp(503, Jason.encode!(payload))
      |> halt()
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Jason.encode!(%{"status" => "ok"}))
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp default_drain_manager,
    do: Application.get_env(:ash_a2a, :cluster_drain_manager, AshA2A.Cluster.DrainManager)

  defp drain_cordoned?(drain_manager) do
    case AshA2A.Cluster.DrainManager.cordoned?(drain_manager) do
      {:ok, cordoned?} -> cordoned?
      {:error, _unavailable} -> false
    end
  end
end
