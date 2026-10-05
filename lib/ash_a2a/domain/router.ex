# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Domain.Router do
  @moduledoc """
  Serves every per-agent mount declared on a domain's `AshA2A.Domain`
  `transport` section: one plug in front of the whole domain's A2A surface,
  dispatching each declared mount to the right transport plug per binding.

  Mirrors ash_json_api's framing, where domain-level route definition
  (`base_route`) is the documented default and per-resource routing is the
  exception. Domain-level mounting is likewise the default recommendation
  here; per-agent `forward` calls remain supported for the exception cases.

      # application endpoint / router
      forward "/", AshA2A.Domain.Router, domain: MyApp.Domain

  Each declared mount is served at its declared path:

      transport do
        mount agent: MyApp.EchoAgent, path: "/echo", binding: :jsonrpc
        mount agent: MyApp.RestAgent, path: "/rest", binding: :rest
      end

      GET  /echo/.well-known/agent-card.json   EchoAgent's card
      POST /echo                               EchoAgent JSON-RPC endpoint
      GET  /rest/.well-known/agent-card.json   RestAgent's card
      POST /rest/message:send                  RestAgent REST surface

  Bindings:

    * `:jsonrpc` -- served by `AshA2A.A2ATransport.Plug` (JSON-RPC 2.0,
      owner-scoped `tasks/*`, SSE streaming).
    * `:rest` -- served by `AshA2A.Transport.HTTPJSON` (A2A v1.0
      HTTP+JSON/REST binding).
    * `:grpc` -- the gRPC binding is served by the real gRPC endpoint
      (`AshA2A.Transport.GRPC.Server.Endpoint`, HTTP/2) on its own port; a
      Plug router cannot speak the gRPC wire protocol, so a `:grpc` mount
      routed through this router answers a typed `501` refusal naming the
      endpoint to start.

  The declared `transport.base_url` is joined with each mount's path and
  handed to the delegate as its `base_url`, so agent cards advertise the
  full mounted URL. Any other options given to the router (e.g.
  `push_notifications: true`, `extended_card: &fun/2`) are forwarded to
  every delegate's `init/1`.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Domain.Info
  alias AshA2A.Domain.Mount
  alias AshA2A.Transport.GRPC.Server.Endpoint, as: GrpcEndpoint
  alias AshA2A.Transport.HTTPJSON

  @typedoc "Pinned router options produced by `init/1`."
  @type opts :: %{
          required(:domain) => module(),
          required(:entries) => [entry()],
          required(:forwarded_opts) => keyword()
        }

  @typep entry :: %{
           required(:prefix) => [String.t()],
           required(:binding) => Mount.binding(),
           required(:plug) => module() | nil,
           required(:plug_opts) => map() | keyword()
         }

  @impl Plug
  def init(opts) do
    domain = Keyword.fetch!(opts, :domain)
    forwarded = Keyword.delete(opts, :domain)

    entries =
      Info.mounts(domain)
      |> Enum.filter(&Mount.agent_mount?/1)
      |> Enum.map(fn %Mount{agent: agent, path: path, binding: binding} ->
        {plug, plug_opts} = binding(binding, agent, path, Info.base_url(domain), forwarded)

        %{
          prefix: prefix_segments(path),
          binding: binding,
          plug: plug,
          plug_opts: plug_opts
        }
      end)

    %{domain: domain, entries: entries, forwarded_opts: forwarded}
  end

  @impl Plug
  def call(%{path_info: path_info} = conn, %{entries: entries}) do
    case route(entries, path_info) do
      {%{binding: :grpc} = entry, _rest} ->
        grpc_refusal(conn, entry)

      {entry, rest} ->
        conn
        |> Map.put(:path_info, rest)
        |> entry.plug.call(entry.plug_opts)

      nil ->
        not_found(conn)
    end
  end

  defp not_found(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "mount_not_found",
          "message" => "no A2A mount is declared at this path"
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
  end

  defp route(entries, path_info) do
    entries
    |> Enum.find_value(fn entry ->
      case List.starts_with?(path_info, entry.prefix) do
        true -> {entry, Enum.drop(path_info, length(entry.prefix))}
        false -> nil
      end
    end)
  end

  # `:grpc` mounts are declared for card/interface advertisement but served
  # by the real gRPC endpoint on its own port; a Plug router cannot speak
  # the gRPC wire protocol. Fail closed with a typed refusal instead of
  # silently serving nothing.
  defp grpc_refusal(conn, entry) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "grpc_not_served_over_http",
          "message" =>
            "mount `#{Enum.join(entry.prefix, "/")}` declares the `:grpc` binding, which is " <>
              "served by #{inspect(GrpcEndpoint)} over HTTP/2 on its own port " <>
              "(GRPC.Server.start_endpoint); a Plug router cannot serve the gRPC wire protocol",
          "details" => %{
            "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
            "reason" => "GRPC_BINDING_NOT_ROUTABLE",
            "domain" => "ash_a2a",
            "metadata" => %{"endpoint" => inspect(GrpcEndpoint)}
          }
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(501, body)
  end

  defp binding(:grpc, _agent, _path, _base_url, _forwarded), do: {nil, []}

  defp binding(binding, agent, path, base_url, forwarded) do
    plug =
      case binding do
        :jsonrpc -> TransportPlug
        :rest -> HTTPJSON
      end

    opts =
      forwarded
      |> Keyword.merge(agent: agent, base_url: mounted_base_url(base_url, path))
      |> then(&plug.init/1)

    {plug, opts}
  end

  defp mounted_base_url(nil, _path), do: nil
  defp mounted_base_url(base_url, path), do: Path.join(base_url, path)

  defp prefix_segments(path) do
    path
    |> String.split("/", trim: true)
  end
end
