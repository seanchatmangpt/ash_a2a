defmodule AshA2A.Health.Plug do
  @moduledoc """
  HTTP surface for `AshA2A.Health`.

    * `GET <mount>/live` -- `200` when `AshA2A.Health.liveness/0` is `:ok`,
      else `503`.
    * `GET <mount>/ready` -- `200` for `:ok`, `503` for `:down`, and for
      `:degraded` the `:degraded_status` option (default `200`: a degraded
      node still serves; pass `degraded_status: 503` to drain it instead).

  Mount it at `/health` in a Phoenix router (`forward "/health",
  AshA2A.Health.Plug`) or match the full `/health/live` / `/health/ready`
  paths directly when used as a top-level plug. Bodies are JSON; they carry
  component status and counts only -- never URLs with credentials, actors,
  or error terms. Any other path or method passes through untouched (the
  conn is returned unhalted and unsent), so the plug composes in a pipeline
  without shadowing routes; the enclosing router decides the `404`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.validate!(opts, degraded_status: 200)

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, opts) do
    case probe(conn.path_info) do
      :live ->
        {status, body} = AshA2A.Health.liveness()
        respond(conn, if(status == :ok, do: 200, else: 503), status, body)

      :ready ->
        {status, body} = AshA2A.Health.readiness()
        respond(conn, http_status(status, opts), status, body)

      :none ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp probe(["health", "live"]), do: :live
  defp probe(["health", "ready"]), do: :ready
  defp probe(["live"]), do: :live
  defp probe(["ready"]), do: :ready
  defp probe(_other), do: :none

  defp http_status(:ok, _opts), do: 200
  defp http_status(:degraded, opts), do: Keyword.fetch!(opts, :degraded_status)
  defp http_status(:down, _opts), do: 503

  defp respond(conn, http_status, status, body) do
    payload = %{"status" => to_string(status), "checks" => jsonable(Map.get(body, :checks, %{}))}

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(http_status, Jason.encode!(payload))
    |> halt()
  end

  @doc false
  def jsonable(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), jsonable(v)} end)

  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value) when is_boolean(value) or is_nil(value), do: value
  def jsonable(value) when is_atom(value), do: value |> inspect() |> String.trim_leading(":")
  def jsonable(value) when is_binary(value) or is_number(value), do: value
  def jsonable(_other), do: nil
end
