if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.Auth do
    @moduledoc """
    Plug middleware for A2A agent authentication.

    Extracts credentials from incoming requests based on configured security
    schemes and delegates validation to a user-supplied `verify` callback.
    On success, the verified identity is stored in `conn.private[:a2a][:auth]`
    where `AshA2A.Protocol.Plug` can forward it to the agent as `context.metadata["a2a.auth"]`.

    ## Usage

        # In a Phoenix pipeline or plug pipeline, before AshA2A.Protocol.Plug:
        plug AshA2A.Protocol.Plug.Auth,
          schemes: %{
            "bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
          },
          verify: &MyApp.Auth.verify_a2a/3

        forward "/a2a", AshA2A.Protocol.Plug, agent: MyAgent, base_url: "..."

    ## Options

    - `:schemes` — `%{String.t() => SecurityScheme.t()}` mapping scheme names
      to their definitions (required)
    - `:verify` — `(scheme_name, credential, conn) -> {:ok, identity} | {:error, reason}`
      callback for credential validation (required)
    - `:security` — `[%{String.t() => [String.t()]}]` list of security
      requirement alternatives. Each map requires all its schemes (AND); the
      first fully-satisfied alternative wins (OR). Defaults to each scheme as
      an independent alternative.
    - `:exempt_paths` — list of path_info lists that bypass authentication
      (default: `[[".well-known", "agent-card.json"]]`)
    - `:realm` — realm string for WWW-Authenticate headers (default: `"a2a"`)

    ## Verify Callback

    The callback receives the scheme name, extracted credential, and conn:

        def verify(scheme_name, credential, conn)

    Where `credential` is:
    - `String.t()` for Bearer tokens, API keys, OAuth2, OpenID Connect
    - `{username, password}` for HTTP Basic auth

    Must return `{:ok, identity_map}` or `{:error, reason_string}`.
    """

    @behaviour Plug

    import Plug.Conn

    alias AshA2A.Protocol.SecurityScheme.{APIKey, HTTPAuth, MutualTLS, OAuth2, OpenIDConnect}

    @default_exempt_paths [[".well-known", "agent-card.json"]]
    @default_realm "a2a"

    # -- Public helpers --------------------------------------------------------

    @doc """
    Returns the authenticated identity from `conn.private[:a2a][:auth]`, or
    `nil` if no identity is stored.
    """
    @spec get_identity(Plug.Conn.t()) :: map() | nil
    def get_identity(conn) do
      conn.private |> Map.get(:a2a, %{}) |> Map.get(:auth)
    end

    @doc """
    Stores an authenticated identity in `conn.private[:a2a][:auth]`.

    Called automatically on successful authentication, but also available
    for use in custom auth plugs that want to integrate with `AshA2A.Protocol.Plug`.
    """
    @spec put_identity(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def put_identity(conn, identity) when is_map(identity) do
      a2a = Map.get(conn.private, :a2a, %{})
      put_private(conn, :a2a, Map.put(a2a, :auth, identity))
    end

    # -- Plug callbacks --------------------------------------------------------

    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      schemes = validate_schemes!(opts)
      verify = validate_verify!(opts)
      security = validate_security!(opts, schemes)
      exempt_paths = Keyword.get(opts, :exempt_paths, @default_exempt_paths)
      realm = Keyword.get(opts, :realm, @default_realm)
      mtls_header = Keyword.get(opts, :mtls_header)

      %{
        mtls_header: mtls_header,
        schemes: schemes,
        verify: verify,
        security: security,
        exempt_paths: exempt_paths,
        realm: realm
      }
    end

    @impl Plug
    @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def call(conn, opts) do
      if exempt?(conn, opts.exempt_paths) do
        conn
      else
        authenticate(conn, opts)
      end
    end

    # -- Init-time validation --------------------------------------------------

    defp validate_schemes!(opts) do
      case Keyword.get(opts, :schemes) do
        nil ->
          raise ArgumentError, "AshA2A.Protocol.Plug.Auth requires :schemes option"

        schemes when is_map(schemes) and map_size(schemes) > 0 ->
          schemes

        _ ->
          raise ArgumentError,
                "AshA2A.Protocol.Plug.Auth :schemes must be a non-empty map"
      end
    end

    defp validate_verify!(opts) do
      case Keyword.get(opts, :verify) do
        fun when is_function(fun, 3) ->
          fun

        nil ->
          raise ArgumentError, "AshA2A.Protocol.Plug.Auth requires :verify option"

        _ ->
          raise ArgumentError,
                "AshA2A.Protocol.Plug.Auth :verify must be a function with arity 3"
      end
    end

    defp validate_security!(opts, schemes) do
      case Keyword.get(opts, :security) do
        nil ->
          # Default: each scheme as an independent alternative (OR)
          Enum.map(schemes, fn {name, _} -> %{name => []} end)

        alternatives when is_list(alternatives) ->
          validate_security_refs!(alternatives, schemes)
          alternatives
      end
    end

    defp validate_security_refs!(alternatives, schemes) do
      scheme_names = Map.keys(schemes) |> MapSet.new()

      Enum.each(alternatives, fn alt ->
        Enum.each(alt, fn {name, _scopes} ->
          unless MapSet.member?(scheme_names, name) do
            raise ArgumentError,
                  "AshA2A.Protocol.Plug.Auth :security references unknown scheme #{inspect(name)}"
          end
        end)
      end)
    end

    # -- Card / config consistency ---------------------------------------------

    @doc """
    Returns `{security_schemes, security}` for splicing into an agent-card
    builder, derived from the same `:schemes` / `:security` options the plug
    enforces, so the advertised card cannot drift from enforced config.

    `security_schemes` is `%{name => scheme_struct}`; `security` is the list
    of requirement alternatives (`[%{name => [scope]}]`).
    """
    @spec card_security(keyword() | map()) ::
            {%{String.t() => struct()}, [%{String.t() => [String.t()]}]}
    def card_security(opts) when is_list(opts), do: opts |> init() |> card_security()

    def card_security(%{schemes: schemes, security: security}), do: {schemes, security}

    # -- Path exemption --------------------------------------------------------

    defp exempt?(conn, exempt_paths) do
      Enum.any?(exempt_paths, &(&1 == conn.path_info))
    end

    # -- Authentication flow ---------------------------------------------------

    defp authenticate(conn, opts) do
      case evaluate_alternatives(conn, opts) do
        {:ok, identity} ->
          put_identity(conn, identity)

        {:insufficient_scope, scopes} ->
          send_insufficient_scope(conn, opts, scopes)

        :unauthorized ->
          send_unauthorized(conn, opts)
      end
    end

    defp insufficient_scope?(%{code: :insufficient_scope}), do: true
    defp insufficient_scope?(:insufficient_scope), do: true
    defp insufficient_scope?(_), do: false

    defp evaluate_alternatives(conn, opts) do
      Enum.reduce_while(opts.security, :unauthorized, fn alt, acc ->
        case evaluate_requirements(conn, alt, opts) do
          {:ok, identities} ->
            identity = build_identity(alt, identities)
            {:halt, {:ok, identity}}

          :unauthorized ->
            {:cont, acc}

          {:insufficient_scope, _} = insufficient ->
            # A scope shortfall is more specific than a plain 401; keep it
            # unless a later alternative authenticates.
            {:cont, if(acc == :unauthorized, do: insufficient, else: acc)}
        end
      end)
    end

    defp safe_verify(verify, name, credential, conn) do
      verify.(name, credential, conn)
    rescue
      # A crashing credential verifier must not escape as a 500 with the
      # exception detail; the caller gets the generic fail-closed 401 and the
      # real reason goes to the logs at the caller's discretion.
      _ -> {:error, :verify_raised}
    end

    defp evaluate_requirements(conn, requirements, opts) do
      results =
        Enum.reduce_while(requirements, %{}, fn {name, scopes}, acc ->
          scheme = Map.fetch!(opts.schemes, name)
          # Declared scopes travel with the conn so verifiers enforce them.
          conn = assign(conn, :a2a_required_scopes, List.wrap(scopes))

          case extract_credential(conn, scheme, opts) do
            {:ok, credential} ->
              # Fail-closed: a crashing verify/3 callback is a 401, never a
              # 500 (the exception detail must not reach the caller either —
              # the 401 body is the generic Unauthorized envelope).
              case safe_verify(opts.verify, name, credential, conn) do
                {:ok, identity} ->
                  {:cont, Map.put(acc, name, identity)}

                {:error, reason} ->
                  if insufficient_scope?(reason) do
                    {:halt, {:insufficient_scope, List.wrap(scopes)}}
                  else
                    {:halt, :unauthorized}
                  end
              end

            :missing ->
              {:halt, :unauthorized}

            :unsupported ->
              {:halt, :unauthorized}
          end
        end)

      case results do
        :unauthorized -> :unauthorized
        {:insufficient_scope, _} = insufficient -> insufficient
        identities when is_map(identities) -> {:ok, identities}
      end
    end

    defp build_identity(requirements, identities) do
      names = Map.keys(requirements)

      case names do
        [single] ->
          %{scheme: single, identity: Map.fetch!(identities, single)}

        _multiple ->
          first = hd(names)

          %{
            scheme: first,
            identity: Map.fetch!(identities, first),
            identities: identities
          }
      end
    end

    # -- Credential extraction -------------------------------------------------

    defp extract_credential(conn, %HTTPAuth{scheme: scheme} = auth, _opts)
         when is_binary(scheme) do
      case String.downcase(scheme) do
        "bearer" -> extract_bearer(conn, auth)
        "basic" -> extract_basic(conn)
        # Digest and unknown schemes are not implemented: fail closed
        # instead of misreading them as bearer tokens.
        _ -> :unsupported
      end
    end

    defp extract_credential(_conn, %HTTPAuth{}, _opts), do: :unsupported

    defp extract_credential(conn, %APIKey{in: "header", name: name}, _opts) do
      case get_req_header(conn, String.downcase(name)) do
        [value | _] -> {:ok, value}
        [] -> :missing
      end
    end

    defp extract_credential(conn, %APIKey{in: "query", name: name}, _opts) do
      conn = fetch_query_params(conn)

      case conn.query_params[name] do
        nil -> :missing
        value -> {:ok, value}
      end
    end

    defp extract_credential(conn, %APIKey{in: "cookie", name: name}, _opts) do
      conn = fetch_cookies(conn)

      case conn.req_cookies[name] do
        nil -> :missing
        value -> {:ok, value}
      end
    end

    defp extract_credential(conn, %OAuth2{}, _opts) do
      extract_bearer(conn)
    end

    defp extract_credential(conn, %OpenIDConnect{}, _opts) do
      extract_bearer(conn)
    end

    # mTLS: the credential is `%{der: binary, fingerprint: hex_sha256,
    # source: :peer | :header}`. The peer certificate comes from the TLS
    # socket (`Plug.Conn.get_peer_data/1`); a forwarded-cert header is only
    # honoured when `:mtls_header` is configured (trusted proxy only).
    defp extract_credential(conn, %MutualTLS{}, opts) do
      case peer_cert(conn) do
        der when is_binary(der) ->
          {:ok, cert_credential(der, :peer)}

        _ ->
          header_cert(conn, Map.get(opts, :mtls_header))
      end
    end

    defp peer_cert(conn) do
      case get_peer_data(conn) do
        %{ssl_cert: der} when is_binary(der) -> der
        _ -> nil
      end
    rescue
      _ -> nil
    end

    defp header_cert(_conn, nil), do: :unsupported

    defp header_cert(conn, header) do
      case get_req_header(conn, String.downcase(header)) do
        [value | _] -> decode_forwarded_cert(value)
        [] -> :missing
      end
    end

    defp decode_forwarded_cert(value) do
      pem = URI.decode(value)

      case :public_key.pem_decode(pem) do
        [{:Certificate, der, _} | _] ->
          {:ok, cert_credential(der, :header)}

        _ ->
          # Not a PEM: accept a bare hex SHA-256 fingerprint from the proxy.
          fp = value |> String.replace(":", "") |> String.downcase()

          if Regex.match?(~r/\A[0-9a-f]{64}\z/, fp) do
            {:ok, %{der: nil, fingerprint: fp, source: :header}}
          else
            :missing
          end
      end
    end

    defp cert_credential(der, source) do
      %{der: der, fingerprint: Base.encode16(:crypto.hash(:sha256, der), case: :lower), source: source}
    end

    # RFC 7235 section 2.1: "the authentication scheme is case-insensitive",
    # so the scheme token is compared downcased on both sides. The credential
    # is whatever follows the scheme token and its single whitespace
    # separator, verbatim.
    defp authorization_scheme_credential(conn) do
      case get_req_header(conn, "authorization") do
        [value | _] ->
          case String.split(value, " ", parts: 2) do
            [scheme, credential] -> {String.downcase(scheme), credential}
            _ -> nil
          end

        [] ->
          nil
      end
    end

    defp extract_bearer(conn, auth \\ nil) do
      case authorization_scheme_credential(conn) do
        {"bearer", token} -> if bearer_format_ok?(auth, token), do: {:ok, token}, else: :missing
        _ -> :missing
      end
    end

    # bearer_format is a documentation hint in OpenAPI, but when declared as
    # "JWT" we reject tokens that are not three dot-separated segments.
    defp bearer_format_ok?(%HTTPAuth{bearer_format: fmt}, token) when is_binary(fmt) do
      if String.upcase(fmt) == "JWT", do: length(String.split(token, ".")) == 3, else: true
    end

    defp bearer_format_ok?(_, _), do: true

    defp extract_basic(conn) do
      case authorization_scheme_credential(conn) do
        {"basic", encoded} ->
          case Base.decode64(encoded) do
            {:ok, decoded} ->
              case String.split(decoded, ":", parts: 2) do
                [user, pass] -> {:ok, {user, pass}}
                _ -> :missing
              end

            :error ->
              :missing
          end

        _ ->
          :missing
      end
    end

    # -- Error response --------------------------------------------------------

    defp send_unauthorized(conn, opts) do
      # RFC 7235 §3.1: a 401 may carry MULTIPLE challenges. put_resp_header/3
      # replaces, so distinct scheme challenges are appended as separate
      # www-authenticate headers in scheme-map order. Schemes with no
      # standard challenge form (api-key, mTLS) contribute none.
      challenges =
        opts.schemes
        |> Enum.map(fn {_name, scheme} -> challenge_for(scheme, opts.realm) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      conn =
        Enum.reduce(challenges, conn, fn challenge, conn ->
          %{conn | resp_headers: conn.resp_headers ++ [{"www-authenticate", challenge}]}
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
      |> halt()
    end

    defp send_insufficient_scope(conn, opts, scopes) do
      challenge =
        "Bearer realm=#{inspect(opts.realm)}, error=\"insufficient_scope\"" <>
          if(scopes == [], do: "", else: ", scope=#{inspect(Enum.join(scopes, " "))}")

      conn
      |> put_resp_header("www-authenticate", challenge)
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{"error" => "insufficient_scope", "scope" => Enum.join(scopes, " ")})
      )
      |> halt()
    end

    defp challenge_for(%HTTPAuth{scheme: scheme}, realm) do
      "#{auth_scheme_token(scheme)} realm=#{inspect(realm)}"
    end

    defp challenge_for(scheme, realm) do
      add_www_authenticate(%Plug.Conn{}, scheme, realm)
      |> Plug.Conn.get_resp_header("www-authenticate")
      |> case do
        [challenge | _] -> challenge
        [] -> nil
      end
    end

    # RFC 7235 challenge tokens: conventional capitalisation ("Bearer",
    # "Basic", "Digest").
    defp auth_scheme_token(scheme) when is_binary(scheme) do
      String.capitalize(String.downcase(scheme))
    end

    defp add_www_authenticate(conn, %OAuth2{}, realm) do
      put_resp_header(conn, "www-authenticate", "Bearer realm=#{inspect(realm)}")
    end

    defp add_www_authenticate(conn, %OpenIDConnect{}, realm) do
      put_resp_header(conn, "www-authenticate", "Bearer realm=#{inspect(realm)}")
    end

    # API key and mTLS have no standard WWW-Authenticate header
    defp add_www_authenticate(conn, _scheme, _realm), do: conn
  end
end
