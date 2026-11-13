if Code.ensure_loaded?(Req) do
  defmodule AshA2A.Protocol.Client.Auth do
    @moduledoc """
    Credential application for `AshA2A.Protocol.Client` (the `:auth` option).

    `:auth` is either

    - a map of `security_scheme_name => credential`, or
    - a callback `fun(requirements) -> headers`, where `requirements` is the
      card's `security` list (`[]` when the client has no card) and `headers`
      is `[{name, value}]`, or a map `%{headers: [...], query: [...], cookies: [...]}`.

    Credential forms in the map:

    - `binary` — bearer token (or an API key when the card's scheme named by the
      map key is an API-key scheme; `"user:pass"` for an HTTP `basic` scheme)
    - `{:bearer, token}`
    - `{:basic, user, pass}` or `{user, pass}`
    - `{:api_key, key}` — placed per the card's API-key scheme, default header
      `x-api-key`
    - `{:api_key, key, in: :header | :query | :cookie, name: "param-name"}`

    The credentials are applied as a `Req` request step, so every call
    (including streams) carries them. Use `parse_challenge/1` to read a
    `WWW-Authenticate` response header.
    """

    alias AshA2A.Protocol.SecurityScheme.{APIKey, HTTPAuth}

    @type placed :: %{
            headers: [{String.t(), String.t()}],
            query: [{String.t(), String.t()}],
            cookies: [{String.t(), String.t()}]
          }

    @type challenge :: %{scheme: String.t(), params: %{String.t() => String.t()}}

    @doc false
    @spec attach(Req.Request.t(), map() | function() | nil, AshA2A.Protocol.AgentCard.t() | nil) ::
            Req.Request.t()
    def attach(req, nil, _card), do: req

    def attach(req, auth, card) when is_map(auth) or is_function(auth, 1) do
      Req.Request.append_request_steps(req,
        a2a_auth: fn request -> apply_to_request(request, credentials(auth, card)) end
      )
    end

    @doc """
    Resolves `auth` against the card into placed credentials (pure; no I/O).
    """
    @spec credentials(map() | function(), AshA2A.Protocol.AgentCard.t() | nil) :: placed()
    def credentials(auth, card) when is_function(auth, 1) do
      requirements = if card, do: card.security || [], else: []

      case auth.(requirements) do
        {:ok, result} -> normalize_callback_result(result)
        result -> normalize_callback_result(result)
      end
    end

    def credentials(auth, card) when is_map(auth) do
      schemes = if card, do: card.security_schemes || %{}, else: %{}

      Enum.reduce(auth, empty(), fn {name, credential}, acc ->
        place(acc, Map.get(schemes, to_string(name)), credential)
      end)
    end

    @doc """
    Parses `WWW-Authenticate` header value(s) into
    `[%{scheme: "Bearer", params: %{"realm" => "x"}}]` (RFC 9110 §11.6.1,
    auth-param form).
    """
    @spec parse_challenge(String.t() | [String.t()] | nil) :: [challenge()]
    def parse_challenge(nil), do: []
    def parse_challenge(values) when is_list(values), do: Enum.flat_map(values, &parse_challenge/1)

    def parse_challenge(value) when is_binary(value) do
      ~r/([A-Za-z][A-Za-z0-9._+-]*)(?=\s|,|$)|([A-Za-z0-9_-]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,"]+))/
      |> Regex.scan(value, capture: :all_but_first)
      |> Enum.reduce([], fn
        [scheme], acc when scheme != "" ->
          [%{scheme: scheme, params: %{}} | acc]

        ["", key, quoted], [current | rest] ->
          [put_param(current, key, unescape(quoted)) | rest]

        ["", key, "", unquoted], [current | rest] ->
          [put_param(current, key, unquoted) | rest]

        _other, acc ->
          acc
      end)
      |> Enum.reverse()
    end

    # -- placement -----------------------------------------------------------

    defp empty, do: %{headers: [], query: [], cookies: []}

    defp place(acc, _scheme, {:bearer, token}), do: header(acc, "authorization", "Bearer " <> token)

    defp place(acc, _scheme, {:basic, user, pass}), do: header(acc, "authorization", basic(user, pass))

    defp place(acc, %HTTPAuth{}, {user, pass}) when is_binary(user) and is_binary(pass),
      do: header(acc, "authorization", basic(user, pass))

    defp place(acc, nil, {user, pass}) when is_binary(user) and is_binary(pass),
      do: header(acc, "authorization", basic(user, pass))

    defp place(acc, scheme, {:api_key, key}) when is_binary(key), do: place_api_key(acc, scheme, key, [])

    defp place(acc, scheme, {:api_key, key, opts}) when is_binary(key) and is_list(opts),
      do: place_api_key(acc, scheme, key, opts)

    defp place(acc, %APIKey{} = scheme, key) when is_binary(key), do: place_api_key(acc, scheme, key, [])

    defp place(acc, %HTTPAuth{scheme: http_scheme}, credential) when is_binary(credential) do
      case http_scheme |> to_string() |> String.downcase() do
        "basic" -> header(acc, "authorization", "Basic " <> Base.encode64(credential))
        _ -> header(acc, "authorization", "Bearer " <> credential)
      end
    end

    defp place(acc, _scheme, credential) when is_binary(credential),
      do: header(acc, "authorization", "Bearer " <> credential)

    defp place(_acc, _scheme, other) do
      raise ArgumentError, "unsupported :auth credential #{inspect(other)}"
    end

    defp place_api_key(acc, scheme, key, opts) do
      location =
        Keyword.get(opts, :in) || scheme_field(scheme, :in) || "header"

      name = Keyword.get(opts, :name) || scheme_field(scheme, :name) || "x-api-key"

      case location |> to_string() |> String.downcase() do
        "query" -> %{acc | query: acc.query ++ [{name, key}]}
        "cookie" -> %{acc | cookies: acc.cookies ++ [{name, key}]}
        _ -> header(acc, String.downcase(name), key)
      end
    end

    defp scheme_field(%APIKey{} = scheme, field), do: Map.get(scheme, field)
    defp scheme_field(_scheme, _field), do: nil

    defp header(acc, name, value), do: %{acc | headers: acc.headers ++ [{name, value}]}

    defp basic(user, pass), do: "Basic " <> Base.encode64(user <> ":" <> pass)

    defp normalize_callback_result(headers) when is_list(headers),
      do: %{empty() | headers: headers}

    defp normalize_callback_result(%{} = map) do
      %{
        headers: Map.get(map, :headers, []),
        query: Map.get(map, :query, []),
        cookies: Map.get(map, :cookies, [])
      }
    end

    # -- request step ----------------------------------------------------------

    defp apply_to_request(request, %{headers: headers, query: query, cookies: cookies}) do
      request = Enum.reduce(headers, request, fn {k, v}, r -> Req.Request.put_header(r, k, v) end)

      request =
        case query do
          [] ->
            request

          pairs ->
            encoded = URI.encode_query(pairs)
            %{request | url: URI.append_query(request.url, encoded)}
        end

      case cookies do
        [] ->
          request

        pairs ->
          Req.Request.put_header(request, "cookie", Enum.map_join(pairs, "; ", fn {k, v} -> k <> "=" <> v end))
      end
    end

    # -- challenge parsing -----------------------------------------------------

    defp put_param(%{params: params} = challenge, key, value),
      do: %{challenge | params: Map.put(params, key, value)}

    defp unescape(quoted), do: String.replace(quoted, ~r/\\(.)/, "\\1")
  end
end
