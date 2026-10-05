# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Passport.Plug do
  @moduledoc """
  Serves the agent passport and its revocation list at well-known GET
  paths.

      plug AshA2A.Passport.Plug,
        passport: my_passport,
        revocation: my_revocation_list

  - `:passport` (required) — an `%AshA2A.Passport.Document{}` or a
    zero-arity function returning one; served at `:passport_path`
    (default `[".well-known", "agent-passport.json"]`) as
    `application/json`.
  - `:revocation` — an `%AshA2A.Passport.Revocation.List{}` or a
    zero-arity function returning one; served at `:revocation_path`
    (default `[".well-known", "agent-passport-revocations.json"]`). When
    absent, the revocation path answers 404.

  Serving is transport, not admission: an expired or revoked passport is
  still served (its status is verifiable material); consumers decide with
  `AshA2A.Passport.verify/2`, which fails closed. Non-matching paths
  answer 404, wrong methods on the served paths answer 405.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.Passport
  alias AshA2A.Passport.Revocation

  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) when is_list(opts) do
    %{
      passport: Keyword.fetch!(opts, :passport),
      revocation: Keyword.get(opts, :revocation),
      passport_path: path(Keyword.get(opts, :passport_path, [".well-known", "agent-passport.json"])),
      revocation_path:
        path(
          Keyword.get(opts, :revocation_path, [
            ".well-known",
            "agent-passport-revocations.json"
          ])
        )
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%{method: "GET", path_info: path} = conn, %{passport_path: path} = opts) do
    serve(conn, fn -> Passport.to_json(resolve(opts.passport)) end)
  end

  def call(%{method: "GET", path_info: path} = conn, %{revocation_path: path, revocation: rev}) do
    if rev do
      serve(conn, fn -> Revocation.to_json(resolve(rev)) end)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  def call(%{path_info: path} = conn, %{passport_path: path}) do
    conn |> put_resp_header("allow", "GET") |> send_resp(405, "Method Not Allowed")
  end

  def call(%{path_info: path} = conn, %{revocation_path: path}) do
    conn |> put_resp_header("allow", "GET") |> send_resp(405, "Method Not Allowed")
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not Found")

  # ------------------------------------------------------------------

  defp resolve(value) when is_function(value, 0), do: value.()
  defp resolve(value), do: value

  defp serve(conn, body_fn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body_fn.())
  end

  defp path(list) when is_list(list), do: list

  defp path(binary) when is_binary(binary),
    do: binary |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
end
