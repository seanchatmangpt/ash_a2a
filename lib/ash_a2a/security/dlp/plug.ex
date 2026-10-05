# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DLPFilter.Plug do
  @moduledoc """
  Bidirectional inline DLP for the A2A HTTP transport (PRD FR-02.1).

  Wraps any inner transport plug and runs `AshA2A.Security.DLPFilter` in
  both directions:

    * **inbound** -- reads the JSON-RPC request body, redacts `params`, and
      serves the inner plug the rewritten body through a `Plug.Conn.Adapter`
      shim, so inner body parsing sees pseudonym tokens, never plaintext;
    * **outbound** -- a before-send hook redacts the JSON response body
      (results, artifacts) before it leaves the process.

  Chunked/SSE streaming responses are out of scope for outbound redaction
  (the before-send hook only sees complete bodies); `message/stream` frames
  are not rewritten by this plug.

  ## Usage

      forward "/a2a", AshA2A.Security.DLPFilter.Plug,
        inner: AshA2A.A2ATransport.Plug,
        agent: MyAgent,
        dlp: [key: secret]

  All options except `:inner` and `:dlp` are forwarded to the inner plug.
  `:dlp` opts are `AshA2A.Security.DLPFilter` opts (`:key`, `:phi_patterns`,
  `:entropy_floor`, `:enabled`).

  Wiring note for lane V4-14's pipeline chain (ARD inbound step 4): when the
  chain lands, its stage calls `AshA2A.Security.DLPFilter.redact/2` on
  inbound `params`; `restore/2` stays available for key-holding
  re-hydration. Until then, mounting this plug in front of the transport is
  the integration surface.
  """

  @behaviour Plug

  import Plug.Conn

  alias AshA2A.Security.DLPFilter
  alias AshA2A.Security.DLPFilter.Plug.Adapter

  defmodule Adapter do
    @moduledoc false

    @behaviour Plug.Conn.Adapter

    @doc false
    def init({mod, state}, body), do: {mod, state, body, false}

    @doc false
    def read_req_body({mod, state, body, sent} = payload, opts) do
      max_length = Keyword.get(opts, :length, 8_000_000)

      cond do
        sent -> {:ok, "", payload}
        body == "" -> {:ok, "", {mod, state, "", true}}
        byte_size(body) <= max_length -> {:ok, body, {mod, state, "", true}}

        true ->
          part = binary_part(body, 0, max_length)
          rest = binary_part(body, max_length, byte_size(body) - max_length)
          {:more, part, {mod, state, rest, false}}
      end
    end

    @doc false
    def send_resp({mod, state, _, _}, status, headers, body),
      do: mod.send_resp(state, status, headers, body)

    @doc false
    def send_file({mod, state, _, _}, status, headers, path, offset, length),
      do: mod.send_file(state, status, headers, path, offset, length)

    @doc false
    def send_chunked({mod, state, _, _}, status, headers),
      do: mod.send_chunked(state, status, headers)

    @doc false
    def chunk({mod, state, _, _}, body), do: mod.chunk(state, body)

    @doc false
    def inform({mod, state, _, _}, status, headers), do: mod.inform(state, status, headers)

    @doc false
    def upgrade({mod, state, _, _}, protocol, opts), do: mod.upgrade(state, protocol, opts)

    @doc false
    def push({mod, state, _, _}, path, headers), do: mod.push(state, path, headers)

    @doc false
    def get_peer_data({mod, state, _, _}), do: mod.get_peer_data(state)

    @doc false
    def get_sock_data({mod, state, _, _}), do: mod.get_sock_data(state)

    @doc false
    def get_ssl_data({mod, state, _, _}), do: mod.get_ssl_data(state)

    @doc false
    def get_http_protocol({mod, state, _, _}), do: mod.get_http_protocol(state)
  end

  @impl Plug
  def init(opts) do
    inner = Keyword.fetch!(opts, :inner)
    dlp = Keyword.get(opts, :dlp, [])
    rest = opts |> Keyword.delete(:inner) |> Keyword.delete(:dlp)
    %{inner: {inner, inner.init(rest)}, dlp: dlp}
  end

  @impl Plug
  def call(%{method: "POST"} = conn, %{inner: {inner_mod, inner_state}, dlp: dlp_opts}) do
    conn
    |> rewrite_request(dlp_opts)
    |> register_before_send(fn conn -> filter_response(conn, dlp_opts) end)
    |> inner_mod.call(inner_state)
  end

  def call(conn, %{inner: {inner_mod, inner_state}, dlp: dlp_opts}) do
    conn
    |> register_before_send(fn conn -> filter_response(conn, dlp_opts) end)
    |> inner_mod.call(inner_state)
  end

  # -- inbound ---------------------------------------------------------------

  defp rewrite_request(conn, dlp_opts) do
    case collect_body(conn, "") do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{"params" => params} = json} when is_map(params) ->
            {redacted, _findings} = DLPFilter.redact(params, dlp_opts)
            wrap(conn, Jason.encode!(%{json | "params" => redacted}))

          {:ok, json} ->
            wrap(conn, Jason.encode!(json))

          _ ->
            wrap(conn, body)
        end

      {:error, _reason} ->
        conn
    end
  end

  defp collect_body(conn, acc, size \\ 0) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 64_000) do
      {:ok, chunk, conn} ->
        body = acc <> chunk
        {:ok, body, conn}

      {:more, chunk, conn} ->
        if size + byte_size(chunk) > 64_000_000 do
          # Fail closed for oversized bodies: never let uninspected bytes
          # reach the inner plug.
          {:error, :dlp_body_too_large}
        else
          collect_body(conn, acc <> chunk, size + byte_size(chunk))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wrap(conn, body) do
    %{conn | adapter: Adapter.init(conn.adapter, body)}
  end

  # -- outbound --------------------------------------------------------------

  defp filter_response(conn, dlp_opts) do
    json? =
      conn
      |> get_resp_header("content-type")
      |> List.first("")
      |> String.contains?("json")

    body = conn.resp_body

    if json? and is_binary(body) and body != "" do
      case Jason.decode(body) do
        {:ok, decoded} ->
          {redacted, _findings} = DLPFilter.redact(decoded, dlp_opts)
          new_body = Jason.encode!(redacted)

          conn
          |> put_resp_header("content-length", Integer.to_string(byte_size(new_body)))
          |> Map.put(:resp_body, new_body)

        _ ->
          conn
      end
    else
      conn
    end
  end
end
