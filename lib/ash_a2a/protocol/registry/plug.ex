if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Registry.Plug do
    @moduledoc """
    Read-only HTTP discovery surface over `AshA2A.Protocol.Registry`.

    **Non-normative:** the A2A specification prescribes no registry API; this
    is an ash_a2a extension. Routes (relative to the forward point):

      * `GET /registry/agents` -- list; query params `skill` (skill id), `tag`,
        `provider`, `input_mode`, `output_mode`, `streaming` (`true`/`false`)
      * `GET /registry/agents/{id}` -- one agent, `id` is `inspect(module)`
        (e.g. `MyApp.PricingAgent`)

    Both answer `200` with `Cache-Control` and a strong `ETag` (a conditional
    `If-None-Match` hit answers `304`), or `404` for an unknown or
    undisclosed agent. A foreign-hidden agent is indistinguishable from a
    missing one.

    ## Auth and disclosure

    Mount behind `AshA2A.Protocol.Plug.Auth` (this plug only reads the verified
    identity through `AshA2A.A2ATransport.Ownership.caller/1`; it never
    authenticates). The principal key is handed to the registry's `:disclose`
    callback so each caller sees its own projection of every card.

    ## Options

      * `:registry` -- registry name (required)
      * `:max_age` -- `Cache-Control` max-age seconds (default `60`)
    """

    @behaviour Plug

    import Plug.Conn

    alias AshA2A.A2ATransport.Ownership
    alias AshA2A.Protocol.Registry

    @impl Plug
    def init(opts) do
      %{registry: Keyword.fetch!(opts, :registry), max_age: Keyword.get(opts, :max_age, 60)}
    end

    @impl Plug
    def call(%Plug.Conn{method: "GET"} = conn, opts) do
      principal = Ownership.caller(conn)

      case route(conn.path_info) do
        :list -> list(conn, opts, principal)
        {:show, id} -> show(conn, opts, principal, id)
        :none -> not_found(conn)
      end
    end

    def call(conn, _opts) do
      conn |> put_resp_header("allow", "GET") |> send_json(405, %{error: "method_not_allowed"})
    end

    defp route(path) do
      case Enum.take(path, -3) do
        ["registry", "agents"] -> :list
        [_, "registry", "agents"] -> :list
        ["registry", "agents", id] -> {:show, id}
        _ -> if tail2(path) == ["registry", "agents"], do: :list, else: :none
      end
    end

    defp tail2(path), do: Enum.take(path, -2)

    defp list(conn, opts, principal) do
      conn = fetch_query_params(conn)
      entries = Registry.list_for(opts.registry, principal, criteria(conn.query_params))

      body =
        Jason.encode!(%{
          agents: entries |> Enum.map(&entry_json/1) |> Enum.sort_by(& &1.id)
        })

      respond(conn, opts, body)
    end

    defp show(conn, opts, principal, id) do
      with {:ok, mod} <- find_module(opts.registry, id),
           {:ok, card} <- Registry.get_for(opts.registry, mod, principal) do
        respond(conn, opts, Jason.encode!(entry_json({mod, card})))
      else
        _ -> not_found(conn)
      end
    end

    # Resolve the id against registered modules; never mint atoms from input.
    defp find_module(registry, id) do
      case Enum.find(Registry.all(registry), fn {mod, _} -> inspect(mod) == id end) do
        {mod, _} -> {:ok, mod}
        nil -> :error
      end
    end

    defp entry_json({mod, card}), do: %{id: inspect(mod), card: card}

    defp criteria(params) do
      %{}
      |> put_param(params, "skill", :skill_id)
      |> put_param(params, "tag", :tag)
      |> put_param(params, "provider", :provider)
      |> put_param(params, "input_mode", :input_mode)
      |> put_param(params, "output_mode", :output_mode)
      |> put_streaming(params)
    end

    defp put_param(acc, params, key, name) do
      case params[key] do
        v when is_binary(v) and v != "" -> Map.put(acc, name, v)
        _ -> acc
      end
    end

    defp put_streaming(acc, %{"streaming" => "true"}),
      do: Map.put(acc, :capabilities, %{streaming: true})

    defp put_streaming(acc, %{"streaming" => "false"}),
      do: Map.put(acc, :capabilities, %{streaming: false})

    defp put_streaming(acc, _), do: acc

    defp respond(conn, opts, body) do
      etag =
        "\"" <>
          (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 32)) <>
          "\""

      conn =
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "max-age=#{opts.max_age}")
        |> put_resp_header("etag", etag)

      if etag in get_req_header(conn, "if-none-match") do
        send_resp(conn, 304, "")
      else
        send_resp(conn, 200, body)
      end
    end

    defp not_found(conn), do: send_json(conn, 404, %{error: "not_found"})

    defp send_json(conn, status, map) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))
    end
  end
end
