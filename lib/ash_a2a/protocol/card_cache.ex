# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Protocol.CardCache do
  @moduledoc """
  Client-side agent-card discovery cache (A2A v1.0, §8.6 "Caching").

  The A2A v1.0 specification (§8.6.2, Client Requirements) says clients
  **SHOULD** honor HTTP caching semantics per RFC 9111, **SHOULD** use
  conditional requests (`If-None-Match` with the stored `ETag`, or
  `If-Modified-Since`) once a cached card has expired, and **MAY** apply an
  implementation-specific default cache duration when the server sends no
  caching headers. This module implements exactly that, on top of the same
  `Req` machinery `AshA2A.Protocol.Client` uses for discovery:

  - **Cold fetch** (`:fresh`) — no cached entry: plain `GET`, store body +
    `ETag` + `Last-Modified` + `Cache-Control` + fetch time on disk, return
    `{:ok, card, :fresh}`.
  - **Warm fetch** (`:cached`) — a cached entry exists and is within its
    `max-age`: return the cached card **without any network request**.
  - **Revalidation** (`:not_modified`) — a cached entry exists and is stale:
    conditional `GET` with `If-None-Match: <stored etag>` (falling back to
    `If-Modified-Since: <stored last-modified>` when no `ETag` was stored).
    A `304 Not Modified` refreshes the stored fetch time and returns
    `{:ok, card, :not_modified}`.
  - **Replaced card** (`:fresh`) — the revalidation answers `200` with a new
    body/`ETag`: replace the stored entry and return `{:ok, card, :fresh}`.
  - **Degraded** (`:stale`) — the revalidation request fails (network error
    or unexpected status) and a cached entry exists: serve the cached card as
    `{:ok, card, :stale}`. With no cached entry the underlying error is
    returned instead.

  The cache is persistent on disk: one JSON file per card URL (SHA-256 of the
  URL as the file name), storing the raw response body, validators, and the
  fetch timestamp, so the cache survives VM restarts.

  ## Options for `fetch/2`

  - `:cache_dir` — directory for the on-disk cache (default:
    `<user cache dir>/ash_a2a/card_cache`)
  - `:agent_card_path` — discovery path (default:
    `"/.well-known/agent-card.json"`, mirroring `AshA2A.Protocol.Client.discover/2`)
  - `:max_age` — client-side `max-age` override in seconds, taking precedence
    over both the server's `Cache-Control` and the built-in default
  - `:headers`, `:timeout`, `:plug` — forwarded to `Req`, mirroring
    `AshA2A.Protocol.Client`'s request options
  - `:now` — current time in milliseconds (test hook; defaults to
    `System.system_time/1`)
  """

  alias AshA2A.Protocol.JSON

  @default_path "/.well-known/agent-card.json"

  # A2A §8.6.2: when the server does not include caching headers, clients MAY
  # apply an implementation-specific default cache duration. 300s mirrors the
  # `Cache-Control: public, max-age=300` this library's own server plug emits.
  @default_max_age_seconds 300

  @type cache_state :: :fresh | :cached | :not_modified | :stale

  @type entry :: %{
          required(:url) => String.t(),
          required(:body) => binary(),
          required(:etag) => String.t() | nil,
          required(:last_modified) => String.t() | nil,
          required(:cache_control) => String.t() | nil,
          required(:fetched_at) => integer()
        }

  @doc """
  Fetches the agent card at `url` through the on-disk cache.

  Returns `{:ok, card, cache_state}` where `cache_state` is `:fresh`,
  `:cached`, `:not_modified`, or `:stale`, or `{:error, reason}` when no
  cached card is available to fall back to.

  ## Examples

      {:ok, card, :fresh} = CardCache.fetch("https://agent.example.com", cache_dir: dir)
      {:ok, card, :cached} = CardCache.fetch("https://agent.example.com", cache_dir: dir)
  """
  @spec fetch(String.t(), keyword()) ::
          {:ok, AshA2A.Protocol.AgentCard.t(), cache_state()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) and is_list(opts) do
    cache_dir = Keyword.get(opts, :cache_dir, default_cache_dir())
    path = Keyword.get(opts, :agent_card_path, @default_path)
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    entry = load(cache_dir, url)

    cond do
      entry != nil and fresh?(entry, max_age(opts, entry), now) ->
        case decode_body(entry.body) do
          {:ok, card} ->
            {:ok, card, :cached}

          {:error, _reason} ->
            # A corrupted/unreadable cache entry must not poison the fetch:
            # fall through to a network revalidation.
            revalidate(url, path, entry, opts, cache_dir, now)
        end

      entry != nil ->
        revalidate(url, path, entry, opts, cache_dir, now)

      true ->
        cold_fetch(url, path, opts, cache_dir, now)
    end
  end

  @doc """
  Decodes a raw agent-card body into an `%AshA2A.Protocol.AgentCard{}`.

  Accepts a raw JSON binary (the exact bytes the `ETag` was computed over) or
  an already-decoded map. Returns `{:ok, card}` or `{:error, reason}`.

      iex> {:ok, card} =
      ...>   AshA2A.Protocol.CardCache.decode_body(%{
      ...>     "name" => "a",
      ...>     "description" => "d",
      ...>     "url" => "https://example.com",
      ...>     "version" => "1.0.0",
      ...>     "skills" => []
      ...>   })
      iex> card.name
      "a"
  """
  @spec decode_body(binary() | map(), keyword()) ::
          {:ok, AshA2A.Protocol.AgentCard.t()} | {:error, term()}
  def decode_body(body, opts \\ [])

  def decode_body(body, _opts) when is_map(body) do
    JSON.decode_agent_card(body)
  end

  def decode_body(body, _opts) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      JSON.decode_agent_card(decoded)
    end
  end

  def decode_body(_body, _opts) do
    {:error, :invalid_card_body}
  end

  # ------------------------------------------------------------------
  # Network paths
  # ------------------------------------------------------------------

  defp cold_fetch(url, path, opts, cache_dir, now) do
    case get(url, path, [], opts) do
      {:ok, %Req.Response{status: 200} = response} ->
        store_response(cache_dir, url, response, now)

        case decode_body(response.body) do
          {:ok, card} -> {:ok, card, :fresh}
          {:error, reason} -> {:error, {:invalid_card, reason}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate(url, path, entry, opts, cache_dir, now) do
    case get(url, path, conditional_headers(entry), opts) do
      {:ok, %Req.Response{status: 304} = response} ->
        # A2A §8.6.2: the conditional request confirmed the card is unchanged.
        # Refresh the stored fetch time (adopting any Cache-Control the server
        # sent alongside the 304) and keep serving the stored body.
        write(cache_dir, %{
          entry
          | fetched_at: now,
            cache_control: response_header(response, "cache-control") || entry.cache_control
        })

        case decode_body(entry.body) do
          {:ok, card} -> {:ok, card, :not_modified}
          {:error, reason} -> {:error, {:invalid_card, reason}}
        end

      {:ok, %Req.Response{status: 200} = response} ->
        store_response(cache_dir, url, response, now)

        case decode_body(response.body) do
          {:ok, card} -> {:ok, card, :fresh}
          {:error, reason} -> {:error, {:invalid_card, reason}}
        end

      {:ok, %Req.Response{status: status}} ->
        stale_or_error(entry, {:unexpected_status, status})

      {:error, reason} ->
        stale_or_error(entry, reason)
    end
  end

  # Mirrors AshA2A.Protocol.Client's request style: Req.new(base_url: url) with
  # the shared :headers/:timeout/:plug option vocabulary, then Req.get/2.
  defp get(url, path, extra_headers, opts) do
    req = Req.new(base_url: url)
    req = merge_req_opts(req, Keyword.take(opts, [:headers, :timeout, :plug]))

    req =
      case extra_headers do
        [] -> req
        headers -> Req.merge(req, headers: headers)
      end

    # Keep the raw bytes: the ETag is computed over the exact body, and the
    # cache stores those bytes so a re-decode never re-fetches.
    Req.get(req, url: path, decode_body: false)
  end

  defp merge_req_opts(req, []), do: req

  # Mirrors AshA2A.Protocol.Client.merge_req_opts/2: same option vocabulary
  # (:headers/:timeout/:plug), same Req translation (:timeout -> receive_timeout).
  defp merge_req_opts(req, opts) do
    Enum.reduce(opts, req, fn
      {:headers, headers}, req -> Req.merge(req, headers: headers)
      {:timeout, timeout}, req -> Req.merge(req, receive_timeout: timeout)
      {:plug, plug}, req -> Req.merge(req, plug: plug)
      _, req -> req
    end)
  end

  defp conditional_headers(%{etag: etag, last_modified: last_modified}) do
    cond do
      is_binary(etag) and etag != "" -> [{"if-none-match", etag}]
      is_binary(last_modified) and last_modified != "" -> [{"if-modified-since", last_modified}]
      true -> []
    end
  end

  defp stale_or_error(nil, reason), do: {:error, reason}

  defp stale_or_error(entry, _reason) do
    case decode_body(entry.body) do
      {:ok, card} -> {:ok, card, :stale}
      {:error, reason} -> {:error, {:invalid_card, reason}}
    end
  end

  # ------------------------------------------------------------------
  # Cache freshness
  # ------------------------------------------------------------------

  defp max_age(opts, entry) do
    case opts[:max_age] do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> parse_max_age(entry.cache_control) || @default_max_age_seconds
    end
  end

  defp parse_max_age(nil), do: nil

  defp parse_max_age(cache_control) when is_binary(cache_control) do
    case Regex.run(~r/max-age\s*=\s*(\d+)/i, cache_control) do
      [_, seconds] -> String.to_integer(seconds)
      _ -> nil
    end
  end

  defp fresh?(entry, max_age_seconds, now) do
    now - entry.fetched_at < max_age_seconds * 1000
  end

  # ------------------------------------------------------------------
  # On-disk persistence — one JSON file per card URL (SHA-256 of the URL)
  # ------------------------------------------------------------------

  defp store_response(cache_dir, url, %Req.Response{body: body} = response, now)
       when is_binary(body) do
    write(cache_dir, %{
      url: url,
      body: body,
      etag: response_header(response, "etag"),
      last_modified: response_header(response, "last-modified"),
      cache_control: response_header(response, "cache-control"),
      fetched_at: now
    })
  end

  defp write(cache_dir, entry) do
    File.mkdir_p!(cache_dir)

    path = cache_path(cache_dir, entry.url)

    File.write!(path, Jason.encode!(%{
      "url" => entry.url,
      "body" => entry.body,
      "etag" => entry.etag,
      "last_modified" => entry.last_modified,
      "cache_control" => entry.cache_control,
      "fetched_at" => entry.fetched_at
    }))
  end

  defp load(cache_dir, url) do
    path = cache_path(cache_dir, url)

    with {:ok, raw} <- File.read(path),
         {:ok, map} <- Jason.decode(raw),
         %{"body" => body, "fetched_at" => fetched_at}
         when is_binary(body) and is_integer(fetched_at) <- map do
      %{
        url: url,
        body: body,
        etag: map["etag"],
        last_modified: map["last_modified"],
        cache_control: map["cache_control"],
        fetched_at: fetched_at
      }
    else
      _ -> nil
    end
  end

  defp cache_path(cache_dir, url) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    Path.join(cache_dir, hash <> ".json")
  end

  defp default_cache_dir do
    Path.join(:filename.basedir(:user_cache, "ash_a2a"), "card_cache")
  end

  defp response_header(%Req.Response{headers: headers}, key) do
    case Map.get(headers, key) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
