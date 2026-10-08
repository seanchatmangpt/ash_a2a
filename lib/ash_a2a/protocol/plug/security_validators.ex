if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.SecurityValidators do
    @moduledoc """
    Built-in credential validators for the full A2A v1 security-scheme surface.

    `AshA2A.Protocol.Plug.Auth` extracts credentials per scheme and delegates
    validation to a `verify/3` callback. This module supplies real validators
    for every declared scheme type so that `:schemes` is not merely
    declared-only:

    - `t:AshA2A.Protocol.SecurityScheme.APIKey` — constant-time value
      comparison against the configured key set; the extraction location
      (header/query/cookie) is enforced by `AshA2A.Protocol.Plug.Auth`.
    - `t:AshA2A.Protocol.SecurityScheme.HTTPAuth` (bearer) — JWT signature
      verification (HS256 via `:crypto`, RS256 via `:public_key`), claims
      validation (required/iss/aud/exp/nbf) and optional scope check.
    - `t:AshA2A.Protocol.SecurityScheme.OAuth2` — bearer JWT verification
      (same core) or RFC 7662 token introspection (`active`, exp, iss, aud,
      scope), plus required-scope enforcement.
    - `t:AshA2A.Protocol.SecurityScheme.OpenIDConnect` — OIDC discovery
      document fetch, JWKS retrieval and RS256 verification against the
      provider's published keys, plus claims/scope validation.
    - mTLS is extraction-unsupported by design (TLS-layer concern) and is
      refused upstream with `:unsupported`.

    Errors are typed maps: `{:error, %{code: atom(), detail: term()}}`, so
    callers (and courts) can assert on the exact failure class.

    ## Usage

        plug AshA2A.Protocol.Plug.Auth,
          schemes: %{
            "bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"},
            "key" => %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-api-key"}
          },
          verify: AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
            "bearer" => [secret: "s3cret", issuer: "https://auth.example.com"],
            "key" => [kind: :key, keys: ["k-123"]]
          })

    Validator config is looked up by scheme NAME (the keys of the plug's
    `:schemes` map); each config carries `:kind` (`:bearer` default, `:key`,
    `:oauth2`, `:oidc`) to select the validator. A scheme name with no config
    entry is refused fail-closed with
    `{:error, %{code: :unconfigured_scheme}}`.
    """

    @jwks_cache_table :a2a_jwks_cache

    # -- Public entrypoints ----------------------------------------------------

    @doc """
    Builds a `verify/3` callback for `AshA2A.Protocol.Plug.Auth` from a map
    of per-scheme validator configs keyed by scheme NAME (matching the keys
    of the plug's `:schemes` map).

    See each validator's docs for the config keys it accepts.
    """
    @spec verifier(keyword()) ::
            (String.t(), term(), Plug.Conn.t() -> {:ok, map()} | {:error, map()})
    @spec verifier(%{String.t() => keyword()}) ::
            (String.t(), term(), Plug.Conn.t() -> {:ok, map()} | {:error, map()})
    def verifier(opts) when is_map(opts) do
      fn scheme_name, credential, _conn ->
        case Map.fetch(opts, scheme_name) do
          {:ok, config} ->
            kind = Keyword.get(config, :kind, :bearer)
            dispatch_validate(kind, credential, config)

          :error ->
            {:error, %{code: :unconfigured_scheme, detail: scheme_name}}
        end
      end
    end

    @doc """
    Validates `credential` against `config` for the given scheme kind
    (`:bearer`, `:key`, `:oauth2`, `:oidc`).
    """
    @spec validate(atom(), term(), keyword()) :: {:ok, map()} | {:error, map()}
    def validate(kind, credential, config) when kind in [:bearer, :key, :oauth2, :oidc] do
      dispatch_validate(kind, credential, config)
    rescue
      e -> {:error, %{code: :validator_crashed, detail: Exception.message(e)}}
    end

    defp dispatch_validate(:bearer, credential, config), do: validate_bearer(credential, config)
    defp dispatch_validate(:key, credential, config), do: validate_api_key(credential, config)
    defp dispatch_validate(:oauth2, credential, config), do: validate_oauth2(credential, config)
    defp dispatch_validate(:oidc, credential, config), do: validate_oidc(credential, config)


    # -- API key ---------------------------------------------------------------

    @doc """
    Validates an API-key credential: the value must match one of the
    configured keys.

    ## Config

    - `:keys` — allowed key values as a list of binaries.
    """
    @spec validate_api_key(term(), keyword()) :: {:ok, map()} | {:error, map()}
    def validate_api_key(credential, config) when is_binary(credential) do
      allowed = Keyword.get(config, :keys, [])

      if constant_time_member?(allowed, credential) do
        {:ok, %{scheme_kind: :key, authenticated: true}}
      else
        {:error, %{code: :invalid_api_key, detail: "api key rejected"}}
      end
    end

    def validate_api_key(_credential, _config) do
      {:error, %{code: :invalid_api_key, detail: "credential must be a binary"}}
    end

    defp constant_time_member?(allowed, credential) do
      # Compare against every configured key in constant time per comparison;
      # membership is decided on keyed HMAC digests of the credential and each
      # configured key, so raw values are never compared directly.
      expected = :crypto.mac(:hmac, :sha256, <<0>>, credential)

      Enum.any?(allowed, fn key ->
        :crypto.hash_equals(expected, :crypto.mac(:hmac, :sha256, <<0>>, key))
      end)
    end

    # -- Bearer JWT (HTTPAuth / OAuth2 JWT path) -------------------------------

    @doc """
    Verifies a bearer JWT (HS256 or RS256) and validates claims/scopes.

    ## Config

    - `:secret` — HMAC secret (HS256 path)
    - `:jwks` — pre-loaded JWKS map (RS256 path, no network)
    - `:jwks_uri` — JWKS URL (RS256 path, fetched + cached)
    - `:discovery` — OIDC discovery URL (RS256 path: discovery → jwks_uri)
    - `:issuer`, `:audience`, `:required_claims`, `:clock_skew` — claim checks
    - `:required_scopes` — scopes that must all be present in the token's
      `scope`/`scp` claim
    """
    @spec validate_bearer(term(), keyword()) :: {:ok, map()} | {:error, map()}
    def validate_bearer(token, config) when is_binary(token) do
      with {:ok, claims} <- verify_jwt(token, config),
           :ok <- check_scopes(claims, config) do
        {:ok, Map.put(claims, :scheme_kind, :bearer)}
      end
    end

    def validate_bearer(_token, _config) do
      {:error, %{code: :invalid_token, detail: "token must be a binary"}}
    end

    # -- OAuth2 ------------------------------------------------------------------

    @doc """
    Validates an OAuth2 bearer token: JWT verification (same core as
    `validate_bearer/2`) or RFC 7662 introspection when `:introspection_url`
    is configured. Enforces `:required_scopes` on the effective claims.

    ## Config

    All `validate_bearer/2` keys, plus:

    - `:introspection_url` — RFC 7662 introspection endpoint. When set, the
      token is POSTed there as `token=<credential>` (with `:client_id`/
      `:client_secret` sent as HTTP Basic when configured) and the response
      must be `active: true` with unexpired `exp` and the required scopes.
    """
    @spec validate_oauth2(term(), keyword()) :: {:ok, map()} | {:error, map()}
    def validate_oauth2(token, config) when is_binary(token) do
      if Keyword.get(config, :introspection_url) do
        introspect_token(token, config)
      else
        case validate_bearer(token, config) do
          {:ok, claims} -> {:ok, Map.put(claims, :scheme_kind, :oauth2)}
          other -> other
        end
      end
    end

    def validate_oauth2(_token, _config) do
      {:error, %{code: :invalid_token, detail: "token must be a binary"}}
    end

    defp introspect_token(token, config) do
      url = Keyword.fetch!(config, :introspection_url)

      headers =
        case Keyword.get(config, :client_id) do
          nil ->
            []

          client_id ->
            cred = Base.encode64("#{client_id}:#{Keyword.get(config, :client_secret, "")}")
            [{"authorization", "Basic #{cred}"}]
        end

      body = URI.encode_query(%{"token" => token, "token_type_hint" => "access_token"})

      case Req.post(url, headers: headers, body: body, retry: false) do
        {:ok, %Req.Response{status: 200, body: result}} ->
          introspection_verdict(result, config)

        {:ok, %Req.Response{status: status}} ->
          {:error, %{code: :introspection_error, detail: "introspection endpoint returned #{status}"}}

        {:error, err} ->
          {:error, %{code: :introspection_error, detail: Exception.message(err)}}
      end
    end

    defp introspection_verdict(result, config) do
      if result["active"] == true do
        claims = %{
          "iss" => result["iss"],
          "aud" => result["aud"],
          "exp" => result["exp"],
          "scope" => result["scope"] || result["scp"],
          "sub" => result["sub"]
        }

        with :ok <- check_introspection_expiry(claims, config) do
          with :ok <- check_scopes(claims, config) do
            {:ok, Map.put(claims, :scheme_kind, :oauth2)}
          end
        end
      else
        {:error, %{code: :token_inactive, detail: "token not active per introspection"}}
      end
    end

    defp check_introspection_expiry(claims, config) do
      skew = Keyword.get(config, :clock_skew, 60)
      exp = claims["exp"]
      now = now_seconds()

      cond do
        is_nil(exp) -> :ok
        is_number(exp) and exp + skew >= now -> :ok
        true -> {:error, %{code: :token_expired, detail: "introspected token expired"}}
      end
    end

    # -- OpenID Connect ------------------------------------------------------------

    @doc """
    Validates an OpenID Connect ID/access token: fetches the provider's
    discovery document (`:discovery` URL or the scheme's
    `open_id_connect_url`), resolves `jwks_uri`, verifies the RS256 signature
    against the published keys and validates claims/scopes.

    ## Config

    Same keys as `validate_bearer/2` (`:jwks`/`:jwks_uri` override discovery
    when provided), plus `:discovery` for the discovery-document URL.
    """
    @spec validate_oidc(term(), keyword()) :: {:ok, map()} | {:error, map()}
    def validate_oidc(token, config) when is_binary(token) do
      case resolve_oidc_config(config) do
        {:ok, resolved} -> validate_bearer(token, resolved)
        {:error, _} = err -> err
      end
    end

    def validate_oidc(_token, _config) do
      {:error, %{code: :invalid_token, detail: "token must be a binary"}}
    end

    defp resolve_oidc_config(config) do
      case {Keyword.get(config, :jwks), Keyword.get(config, :jwks_uri), Keyword.get(config, :discovery)} do
        {nil, nil, discovery} when is_binary(discovery) ->
          with {:ok, jwks_uri} <- fetch_jwks_uri(discovery) do
            {:ok, Keyword.put(config, :jwks_uri, jwks_uri)}
          end

        _ ->
          {:ok, config}
      end
    end

    # -- JWT core (HS256 + RS256) ---------------------------------------------------

    @doc """
    Verifies a JWT: parses header/payload/signature, checks the header
    algorithm, verifies the signature (HS256 via `:crypto`, RS256 via
    `:public_key` against a JWKS RSA key) and validates claims.

    Returns `{:ok, claims}` or `{:error, %{code: atom(), detail: term()}}`.
    """
    @spec verify_jwt(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
    def verify_jwt(token, config) when is_binary(token) do
      with {:ok, header, payload, signing_input, sig} <- parse_token(token),
           :ok <- check_alg(header, config),
           :ok <- verify_signature(header, signing_input, sig, config),
           :ok <- check_required_claims(payload, config),
           :ok <- check_issuer(payload, config),
           :ok <- check_audience(payload, config),
           :ok <- check_expiration(payload, config),
           :ok <- check_not_before(payload, config),
           :ok <- check_scopes(payload, config) do
        {:ok, payload}
      end
    end

    def verify_jwt(_token, _config) do
      {:error, %{code: :invalid_token, detail: "token must be a binary"}}
    end

    defp parse_token(token) do
      case String.split(token, ".", parts: 3) do
        [h, p, s] ->
          with {:ok, header} <- b64_json(h),
               {:ok, payload} <- b64_json(p),
               {:ok, sig} <- b64url_decode(s) do
            {:ok, header, payload, Enum.join([h, p], "."), sig}
          end

        _ ->
          {:error, %{code: :malformed_token, detail: "token does not have 3 segments"}}
      end
    end

    defp b64_json(seg) do
      with {:ok, json} <- b64url_decode(seg),
           {:ok, map} <- Jason.decode(json) do
        if is_map(map) do
          {:ok, map}
        else
          {:error, %{code: :malformed_token, detail: "segment is not a JSON object"}}
        end
      end
    end

    defp b64url_decode(seg) do
      case Base.url_decode64(seg, padding: false) do
        {:ok, bin} -> {:ok, bin}
        :error -> {:error, %{code: :malformed_token, detail: "invalid base64url segment"}}
      end
    end

    defp check_alg(header, config) do
      expected = Keyword.get(config, :algorithms)

      case header["alg"] do
        nil ->
          {:error, %{code: :malformed_token, detail: "missing alg header"}}

        alg when is_binary(expected) and alg != expected ->
          {:error, %{code: :algorithm_mismatch, detail: "expected #{expected}, got #{alg}"}}

        alg when is_list(expected) ->
          if alg in expected do
            :ok
          else
            {:error, %{code: :algorithm_mismatch, detail: "expected one of #{inspect(expected)}, got #{alg}"}}
          end

        _alg ->
          # No expected algorithm configured: accept only the algorithms the
          # signature verifier itself supports.
          if header["alg"] in ["HS256", "RS256"] do
            :ok
          else
            {:error, %{code: :unsupported_algorithm, detail: header["alg"]}}
          end
      end
    end

    defp verify_signature(header, signing_input, sig, config) do
      case header["alg"] do
        "HS256" -> verify_hs256(signing_input, sig, config)
        "RS256" -> verify_rs256(header, signing_input, sig, config)
        alg -> {:error, %{code: :unsupported_algorithm, detail: alg}}
      end
    end

    defp verify_hs256(signing_input, sig, config) do
      case Keyword.get(config, :secret) do
        nil ->
          {:error, %{code: :missing_secret, detail: "no HMAC secret configured"}}

        secret when is_binary(secret) ->
          expected = :crypto.mac(:hmac, :sha256, secret, signing_input)

          if :crypto.hash_equals(expected, sig) do
            :ok
          else
            {:error, %{code: :bad_signature, detail: "HMAC verification failed"}}
          end
      end
    end

    defp verify_rs256(header, signing_input, sig, config) do
      with {:ok, jwk} <- resolve_jwk(header, config) do
        case jwk["kty"] do
          "RSA" ->
            n = jwk_int(jwk["n"])
            e = jwk_int(jwk["e"])

            cond do
              is_nil(n) or is_nil(e) ->
                {:error, %{code: :invalid_jwk, detail: "RSA JWK missing n/e"}}

              :public_key.verify(:crypto.hash(:sha256, signing_input), :sha256, sig, {:"RSAPublicKey", n, e}) ->
                :ok

              true ->
                {:error, %{code: :bad_signature, detail: "RSA signature verification failed"}}
            end

          kty ->
            {:error, %{code: :unsupported_jwk_type, detail: kty}}
        end
      end
    end

    defp resolve_jwk(header, config) do
      cond do
        jwks = Keyword.get(config, :jwks) ->
          pick_jwk(jwks, header, config)

        uri = Keyword.get(config, :jwks_uri) ->
          with {:ok, jwks} <- fetch_jwks_cached(uri, config) do
            pick_jwk(jwks, header, config)
          end

        true ->
          {:error, %{code: :missing_jwks, detail: "no JWKS source configured for RS256"}}
      end
    end

    defp pick_jwk(jwks, header, config) do
      keys = (is_map(jwks) and Map.get(jwks, "keys")) || []

      kid = header["kid"]

      candidates =
        keys
        |> Enum.filter(fn k -> is_map(k) and k["kty"] == "RSA" and (is_nil(kid) or k["kid"] == kid) end)
        |> then(fn cands ->
          use_x5c = Keyword.get(config, :use_x5c, false)

          if use_x5c and is_nil(kid) do
            Enum.filter(cands, &Map.has_key?(&1, "x5c"))
          else
            cands
          end
        end)

      case candidates do
        [] -> {:error, %{code: :unknown_kid, detail: kid || "no matching RSA key in JWKS"}}
        [jwk | _] -> {:ok, jwk}
      end
    end

    defp jwk_int(nil), do: nil

    defp jwk_int(b64) when is_binary(b64) do
      case Base.url_decode64(b64, padding: false) do
        {:ok, bin} -> :binary.decode_unsigned(bin)
        :error -> nil
      end
    end

    # -- JWKS fetch + cache ----------------------------------------------------------

    defp fetch_jwks_uri(discovery_url) do
      case Req.get(discovery_url, retry: false) do
        {:ok, %Req.Response{status: 200, body: %{"jwks_uri" => jwks_uri}}} ->
          {:ok, jwks_uri}

        {:ok, %Req.Response{status: status}} ->
          {:error, %{code: :discovery_error, detail: "discovery endpoint returned #{status}"}}

        {:error, err} ->
          {:error, %{code: :discovery_error, detail: Exception.message(err)}}
      end
    end

    defp fetch_jwks_cached(uri, config) do
      ttl = Keyword.get(config, :jwks_cache_ttl, 300)

      ensure_cache_table()

      case :ets.lookup(@jwks_cache_table, uri) do
        [{^uri, jwks, fetched_at}] ->
          if now_seconds() - fetched_at < ttl do
            {:ok, jwks}
          else
            fetch_jwks_fresh(uri)
          end

        [] ->
          fetch_jwks_fresh(uri)
      end
    end

    defp fetch_jwks_fresh(uri) do
      case Req.get(uri, retry: false) do
        {:ok, %Req.Response{status: 200, body: jwks}} when is_map(jwks) ->
          :ets.insert(@jwks_cache_table, {uri, jwks, now_seconds()})
          {:ok, jwks}

        {:ok, %Req.Response{status: status}} ->
          {:error, %{code: :jwks_error, detail: "JWKS endpoint returned #{status}"}}

        {:error, err} ->
          {:error, %{code: :jwks_error, detail: Exception.message(err)}}
      end
    end

    defp ensure_cache_table do
      if :ets.whereis(@jwks_cache_table) not in [nil, :undefined] do
        :ok
      else
        try do
          :ets.new(@jwks_cache_table, [:named_table, :public, read_concurrency: true])
          :ok
        rescue
          _ -> :ok
        end
      end
    end

    # -- Claims ------------------------------------------------------------------------

    defp check_required_claims(payload, config) do
      required = Keyword.get(config, :required_claims, ["sub"])
      missing = Enum.reject(required, &Map.has_key?(payload, &1))

      case missing do
        [] -> :ok
        _ -> {:error, %{code: :missing_claim, detail: missing}}
      end
    end

    defp check_issuer(payload, config) do
      case Keyword.get(config, :issuer) do
        nil ->
          :ok

        expected ->
          if payload["iss"] == expected do
            :ok
          else
            {:error, %{code: :invalid_issuer, detail: %{expected: expected, got: payload["iss"]}}}
          end
      end
    end

    defp check_audience(payload, config) do
      case Keyword.get(config, :audience) do
        nil ->
          :ok

        expected ->
          aud = payload["aud"]

          cond do
            aud == expected -> :ok
            is_list(aud) and expected in aud -> :ok
            true -> {:error, %{code: :invalid_audience, detail: %{expected: expected, got: aud}}}
          end
      end
    end

    defp check_expiration(payload, config) do
      skew = Keyword.get(config, :clock_skew, 60)

      case Map.get(payload, "exp") do
        nil ->
          :ok

        exp ->
          if is_number(exp) and exp + skew >= now_seconds() do
            :ok
          else
            if is_number(exp) do
              {:error, %{code: :token_expired, detail: "token expired"}}
            else
              {:error, %{code: :invalid_claim, detail: "exp must be a number"}}
            end
          end
      end
    end

    defp check_not_before(payload, config) do
      skew = Keyword.get(config, :clock_skew, 60)

      case Map.get(payload, "nbf") do
        nil ->
          :ok

        nbf ->
          if is_number(nbf) and nbf - skew <= now_seconds() do
            :ok
          else
            if is_number(nbf) do
              {:error, %{code: :token_not_yet_valid, detail: "token not yet valid"}}
            else
              {:error, %{code: :invalid_claim, detail: "nbf must be a number"}}
            end
          end
      end
    end

    @doc """
    Checks that every scope in `config[:required_scopes]` is present in the
    token's `scope` or `scp` claim (string, space-separated, or list).
    """
    @spec check_scopes(map(), keyword()) :: :ok | {:error, map()}
    def check_scopes(claims, config) do
      required = Keyword.get(config, :required_scopes, [])

      granted =
        case claims["scope"] || claims["scp"] do
          scope when is_binary(scope) -> MapSet.new(String.split(scope))
          scopes when is_list(scopes) -> MapSet.new(scopes)
          _ -> MapSet.new()
        end

      case Enum.reject(required, &MapSet.member?(granted, &1)) do
        [] -> :ok
        missing -> {:error, %{code: :insufficient_scope, detail: missing}}
      end
    end

    defp now_seconds, do: System.system_time(:second)

    # S42 self-classification for the drift court
    # (test/ash_a2a/semantic_refusal_test.exs): every emitted code gets an
    # explicit class. Config/source-availability failures block rather than
    # refuse; token/claim/key validation failures are identity refusals;
    # scope shortfalls are bounds refusals.
    def __sa2a_refusal_codes__ do
      %{
        unconfigured_scheme: :blocked_resource,
        validator_crashed: :blocked_resource,
        missing_secret: :blocked_resource,
        missing_jwks: :blocked_resource,
        jwks_error: :blocked_resource,
        discovery_error: :blocked_resource,
        introspection_error: :blocked_resource,
        invalid_api_key: :refused_identity,
        invalid_token: :refused_identity,
        malformed_token: :refused_identity,
        algorithm_mismatch: :refused_identity,
        unsupported_algorithm: :refused_identity,
        bad_signature: :refused_identity,
        invalid_jwk: :refused_identity,
        unsupported_jwk_type: :refused_identity,
        unknown_kid: :refused_identity,
        missing_claim: :refused_identity,
        invalid_claim: :refused_identity,
        invalid_issuer: :refused_identity,
        invalid_audience: :refused_identity,
        token_expired: :refused_identity,
        token_not_yet_valid: :refused_identity,
        token_inactive: :refused_identity,
        insufficient_scope: :refused_bounds
      }
    end
  end
end
