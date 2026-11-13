if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.OIDCDiscovery do
    @moduledoc """
    OIDC discovery with a TTL cache.

    Fetches `{issuer}/.well-known/openid-configuration`, checks the document's
    `issuer` equals the requested issuer (OIDC Discovery 1.0 section 4.3), resolves
    `jwks_uri`, and fetches the JWKS. Documents and JWKS are cached in
    `:persistent_term` (no owning process) for `:ttl` seconds (default 300).

        {:ok, jwks} = OIDCDiscovery.jwks("https://idp.example.com")

        # feed the existing JWKS verification
        config = OIDCDiscovery.verifier_config("https://idp.example.com", audience: "a2a")
        SecurityValidators.verify_jwt(token, config)

    Options: `:ttl` (seconds), `:force` (bypass cache).
    """

    @default_ttl 300

    @type error :: %{code: atom(), detail: term()}

    @doc "Discovery document for `issuer`."
    @spec discover(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
    def discover(issuer, opts \\ []) when is_binary(issuer) do
      cached({:doc, issuer}, opts, fn -> fetch_doc(issuer) end)
    end

    @doc "`jwks_uri` advertised by `issuer`."
    @spec jwks_uri(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
    def jwks_uri(issuer, opts \\ []) do
      with {:ok, doc} <- discover(issuer, opts) do
        case doc["jwks_uri"] do
          uri when is_binary(uri) and uri != "" -> {:ok, uri}
          _ -> {:error, %{code: :discovery_error, detail: "document has no jwks_uri"}}
        end
      end
    end

    @doc "JWKS for `issuer` (discovery -> jwks_uri -> fetch), cached."
    @spec jwks(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
    def jwks(issuer, opts \\ []) do
      with {:ok, uri} <- jwks_uri(issuer, opts) do
        cached({:jwks, uri}, opts, fn -> fetch_jwks(uri) end)
      end
    end

    @doc """
    Keyword config for `AshA2A.Protocol.Plug.SecurityValidators.verify_jwt/2`:
    `jwks:` resolved via discovery, `issuer:` pinned, `algorithms: "RS256"`, plus `extra`.
    """
    @spec verifier_config(String.t(), keyword()) :: {:ok, keyword()} | {:error, error()}
    def verifier_config(issuer, extra \\ []) do
      {opts, extra} = Keyword.split(extra, [:ttl, :force])

      with {:ok, jwks} <- jwks(issuer, opts) do
        {:ok,
         Keyword.merge([algorithms: "RS256", issuer: issuer], extra) |> Keyword.put(:jwks, jwks)}
      end
    end

    @doc "Drops every cached discovery document and JWKS."
    @spec clear() :: :ok
    def clear do
      for {{__MODULE__, _, _} = k, _} <- :persistent_term.get(), do: :persistent_term.erase(k)
      :ok
    end

    # -- internals ---------------------------------------------------------------

    defp cached(key, opts, fun) do
      pt = {__MODULE__, elem(key, 0), elem(key, 1)}
      ttl = Keyword.get(opts, :ttl, @default_ttl)
      now = System.monotonic_time(:second)

      case not Keyword.get(opts, :force, false) && :persistent_term.get(pt, nil) do
        {value, at} when now - at < ttl ->
          {:ok, value}

        _ ->
          with {:ok, value} <- fun.() do
            :persistent_term.put(pt, {value, now})
            {:ok, value}
          end
      end
    end

    defp fetch_doc(issuer) do
      url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

      case Req.get(url, retry: false, decode_body: true) do
        {:ok, %Req.Response{status: 200, body: %{"issuer" => ^issuer} = doc}} ->
          {:ok, doc}

        {:ok, %Req.Response{status: 200, body: %{"issuer" => other}}} ->
          {:error, %{code: :discovery_error, detail: "issuer mismatch: #{inspect(other)}"}}

        {:ok, %Req.Response{status: 200}} ->
          {:error, %{code: :discovery_error, detail: "invalid discovery document"}}

        {:ok, %Req.Response{status: status}} ->
          {:error, %{code: :discovery_error, detail: "discovery endpoint returned #{status}"}}

        {:error, err} ->
          {:error, %{code: :discovery_error, detail: Exception.message(err)}}
      end
    end

    defp fetch_jwks(uri) do
      case Req.get(uri, retry: false, decode_body: true) do
        {:ok, %Req.Response{status: 200, body: %{"keys" => keys} = jwks}} when is_list(keys) ->
          {:ok, jwks}

        {:ok, %Req.Response{status: 200}} ->
          {:error, %{code: :jwks_error, detail: "invalid JWKS document"}}

        {:ok, %Req.Response{status: status}} ->
          {:error, %{code: :jwks_error, detail: "JWKS endpoint returned #{status}"}}

        {:error, err} ->
          {:error, %{code: :jwks_error, detail: Exception.message(err)}}
      end
    end
  end
end
