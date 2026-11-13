if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.CardServe do
    @moduledoc """
    Shared Agent Card serving helpers for `AshA2A.Protocol.Plug` and
    `AshA2A.Transport.Plug` (A2A v1.0 §8.6.1 distribution headers):

      * `respond/5` -- conditional GET: `If-None-Match` (RFC 9110 §13.1.2, weak
        comparison, comma-separated value lists, `*`) takes precedence over
        `If-Modified-Since` (§13.1.3); a satisfied precondition answers `304`
        carrying the SAME `ETag` / `Last-Modified` / `Cache-Control` headers.
      * `signed_body/2` -- serve-time card signing (`:sign_with`), memoised by
        the unsigned body so the signed bytes -- and therefore the `ETag` --
        are stable across requests even for randomised signature algorithms
        (ES256).
      * `http_date/1` / `parse_http_date/1` -- IMF-fixdate round trip.
    """

    import Plug.Conn

    @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    @doc """
    Sends the card `body` with `etag`, `last_modified` (an IMF-fixdate string)
    and `cache_control`, or a `304` with the same headers when the request's
    validators match.
    """
    @spec respond(Plug.Conn.t(), binary(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
    def respond(conn, body, etag, last_modified, cache_control) do
      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("last-modified", last_modified)
        # Plug defaults every response to "max-age=0, private, must-revalidate",
        # which is wrong for a public, shareable agent card.
        |> put_resp_header("cache-control", cache_control)

      if not_modified?(conn, etag, last_modified) do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
      end
    end

    @doc """
    Whether the request's conditional headers are satisfied by the current
    representation (`etag`, `last_modified`).
    """
    @spec not_modified?(Plug.Conn.t(), String.t(), String.t()) :: boolean()
    def not_modified?(conn, etag, last_modified) do
      case get_req_header(conn, "if-none-match") do
        [] -> modified_since_check(conn, last_modified)
        values -> none_match?(values, etag)
      end
    end

    defp none_match?(values, etag) do
      candidates =
        values
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      "*" in candidates or Enum.any?(candidates, &(weak_tag(&1) == weak_tag(etag)))
    end

    # Weak comparison (RFC 9110 §8.8.3.2): the `W/` prefix is ignored.
    defp weak_tag("W/" <> tag), do: tag
    defp weak_tag(tag), do: tag

    defp modified_since_check(conn, last_modified) do
      with [ims | _] <- get_req_header(conn, "if-modified-since"),
           {:ok, since} <- parse_http_date(ims),
           {:ok, current} <- parse_http_date(last_modified) do
        current <= since
      else
        _ -> false
      end
    end

    @doc "Formats a `DateTime` as an RFC 9110 IMF-fixdate (UTC)."
    @spec http_date(DateTime.t()) :: String.t()
    def http_date(%DateTime{} = dt) do
      dt
      |> DateTime.to_unix()
      |> DateTime.from_unix!()
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
    end

    @doc "Parses an IMF-fixdate into Unix seconds."
    @spec parse_http_date(String.t()) :: {:ok, integer()} | :error
    def parse_http_date(value) when is_binary(value) do
      case Regex.run(
             ~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
             String.trim(value)
           ) do
        [_, d, mon, y, h, mi, s] ->
          with month when not is_nil(month) <- Enum.find_index(@months, &(&1 == mon)),
               {day, ""} <- Integer.parse(d),
               {year, ""} <- Integer.parse(y),
               true <- :calendar.valid_date(year, month + 1, day) do
            {hour, ""} = Integer.parse(h)
            {min, ""} = Integer.parse(mi)
            {sec, ""} = Integer.parse(s)

            gregorian =
              :calendar.datetime_to_gregorian_seconds({{year, month + 1, day}, {hour, min, sec}})

            {:ok, gregorian - 62_167_219_200}
          else
            _ -> :error
          end

        _ ->
          :error
      end
    end

    def parse_http_date(_), do: :error

    @doc """
    Encodes `json` (the wire card map) to a body binary, signing it first when
    `sign_with` (`[key:, alg:, kid:]`, forwarded to
    `AshA2A.Protocol.CardSigner.sign/2`) is configured. The signed body is
    memoised under the digest of the unsigned body and the signing options, so
    repeated requests serve byte-identical bytes (stable `ETag`).
    """
    @spec signed_body(map(), keyword() | nil) :: binary()
    def signed_body(json, nil), do: Jason.encode!(json)

    def signed_body(json, sign_with) when is_list(sign_with) do
      unsigned = Jason.encode!(json)

      cache_key =
        {__MODULE__, :signed,
         :crypto.hash(:sha256, [unsigned, :erlang.term_to_binary(Enum.sort(sign_with))])}

      case :persistent_term.get(cache_key, nil) do
        nil ->
          body = json |> AshA2A.Protocol.CardSigner.sign(sign_with) |> Jason.encode!()
          :persistent_term.put(cache_key, body)
          body

        body ->
          body
      end
    end
  end
end
