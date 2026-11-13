# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.DowngradeWire do
  @moduledoc """
  Conn-side glue for `AshA2A.Protocol.Downgrade` at the final-encoding choke
  points. A downgrade applies only when the request carried an EXPLICIT
  `A2A-Version` (header, or the same-named query parameter); an absent header
  is `nil` here, so nothing is dropped (the conn's `"0.3"` default is not an
  explicit negotiation).
  """

  alias AshA2A.Protocol.{Downgrade, Version}

  @doc "The explicit negotiated version of `conn`, or `nil`."
  @spec version(Plug.Conn.t()) :: String.t() | nil
  def version(%Plug.Conn{} = conn) do
    explicit? =
      Enum.any?(conn.req_headers, fn {k, v} -> k == "a2a-version" and String.trim(v) != "" end) or
        String.contains?(conn.query_string || "", "A2A-Version=")

    if explicit?, do: Version.from_conn(conn), else: nil
  end

  def version(_), do: nil

  @doc "Strips v1.1-only keys from a response body for a pre-1.1 consumer."
  @spec body(Plug.Conn.t(), term()) :: term()
  def body(conn, term) do
    case version(conn) do
      nil -> term
      v -> Downgrade.to_wire(term, v)
    end
  end

  @doc """
  Downgrades one SSE payload (a bare stream response or a JSON-RPC envelope).
  Returns `:drop` for v1.1-only frames on a pre-1.1 consumer.
  """
  @spec frame(Plug.Conn.t(), term()) :: {:ok, term()} | :drop
  def frame(conn, payload) do
    case version(conn) do
      nil ->
        {:ok, payload}

      v ->
        if drop?(payload, v), do: :drop, else: {:ok, Downgrade.to_wire(payload, v)}
    end
  end

  defp drop?(%{"result" => %{} = result} = envelope, v),
    do: Downgrade.drop_frame?(envelope, v) or Downgrade.drop_frame?(result, v)

  defp drop?(%{} = frame, v), do: Downgrade.drop_frame?(frame, v)
  defp drop?(_, _), do: false
end
