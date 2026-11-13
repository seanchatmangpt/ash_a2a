if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Protocol.Plug.ApiKeyVerifier do
    @moduledoc """
    API-key verification for the `apiKeySecurityScheme`.

    The key location comes from the scheme's `in` (`"header"`, `"query"`, `"cookie"`)
    and `name`. Comparison is constant-time (`:crypto.hash_equals/2` over keyed
    digests, every configured key is always compared).

        verifier =
          ApiKeyVerifier.new(
            scheme: %AshA2A.Protocol.SecurityScheme.APIKey{in: "header", name: "x-api-key"},
            keys: %{"svc-a" => "s3cret-a"}   # or a plain list of binaries
          )

        # standalone
        {:ok, %{identity: "svc-a"}} = ApiKeyVerifier.authenticate(verifier, conn)

        # wired into Auth through its existing :verify opt (no change to auth.ex)
        plug AshA2A.Protocol.Plug.Auth,
          schemes: %{"key" => scheme},
          verify: ApiKeyVerifier.verify_fun(%{"key" => verifier})

    Errors are `{:error, %{code: :invalid_api_key | :missing_api_key, detail: String.t()}}`.
    """

    alias AshA2A.Protocol.SecurityScheme.APIKey

    @enforce_keys [:scheme, :keys]
    defstruct [:scheme, :keys]

    @type t :: %__MODULE__{scheme: APIKey.t(), keys: [{String.t() | nil, binary()}]}

    @doc "Builds a verifier from `scheme:` (an `APIKey`) and `keys:` (list or `%{identity => key}`)."
    @spec new(keyword()) :: t()
    def new(opts) do
      %APIKey{} = scheme = Keyword.fetch!(opts, :scheme)

      keys =
        case Keyword.fetch!(opts, :keys) do
          %{} = m -> Enum.map(m, fn {id, key} -> {to_string(id), key} end)
          list when is_list(list) -> Enum.map(list, &{nil, &1})
        end

      %__MODULE__{scheme: scheme, keys: keys}
    end

    @doc "Extracts the credential per the scheme's `in`/`name`; `nil` when absent."
    @spec extract(t(), Plug.Conn.t()) :: binary() | nil
    def extract(%__MODULE__{scheme: %APIKey{in: "header", name: name}}, conn) do
      conn |> Plug.Conn.get_req_header(String.downcase(name)) |> first_value()
    end

    def extract(%__MODULE__{scheme: %APIKey{in: "query", name: name}}, conn) do
      case Plug.Conn.fetch_query_params(conn).query_params[name] do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end

    def extract(%__MODULE__{scheme: %APIKey{in: "cookie", name: name}}, conn) do
      case Plug.Conn.fetch_cookies(conn).req_cookies[name] do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end

    def extract(_verifier, _conn), do: nil

    defp first_value([v | _]) when is_binary(v) and v != "", do: v
    defp first_value(_), do: nil

    @doc "Extracts and verifies the credential from `conn`."
    @spec authenticate(t(), Plug.Conn.t()) :: {:ok, map()} | {:error, map()}
    def authenticate(%__MODULE__{} = verifier, conn) do
      case extract(verifier, conn) do
        nil -> {:error, %{code: :missing_api_key, detail: "api key not supplied"}}
        credential -> verify(verifier, credential)
      end
    end

    @doc "Verifies an already-extracted credential."
    @spec verify(t(), term()) :: {:ok, map()} | {:error, map()}
    def verify(%__MODULE__{keys: keys}, credential) when is_binary(credential) do
      digest = digest(credential)

      # Compare against every key (no early exit) so timing does not reveal which matched.
      matched =
        Enum.reduce(keys, nil, fn {id, key}, acc ->
          if :crypto.hash_equals(digest, digest(key)) do
            acc || {:match, id}
          else
            acc
          end
        end)

      case matched do
        {:match, id} ->
          {:ok, %{scheme_kind: :key, authenticated: true, identity: id, sub: id}}

        nil ->
          {:error, %{code: :invalid_api_key, detail: "api key rejected"}}
      end
    end

    def verify(_verifier, _credential),
      do: {:error, %{code: :invalid_api_key, detail: "credential must be a binary"}}

    @doc """
    `verify/3` callback for `AshA2A.Protocol.Plug.Auth`'s `:verify` opt:
    `verifiers` maps scheme name to a verifier; unknown names are refused.
    """
    @spec verify_fun(%{String.t() => t()}) ::
            (String.t(), term(), Plug.Conn.t() -> {:ok, map()} | {:error, map()})
    def verify_fun(verifiers) when is_map(verifiers) do
      fn name, credential, _conn ->
        case Map.fetch(verifiers, name) do
          {:ok, verifier} -> verify(verifier, credential)
          :error -> {:error, %{code: :unconfigured_scheme, detail: name}}
        end
      end
    end

    defp digest(value), do: :crypto.mac(:hmac, :sha256, <<0>>, value)
  end
end
