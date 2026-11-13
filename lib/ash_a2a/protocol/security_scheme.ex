defmodule AshA2A.Protocol.SecurityScheme do
  @moduledoc """
  Union type over the five A2A security scheme types.

  Each scheme maps to a discriminator key in the wire format:

  - `"apiKeySecurityScheme"` → `%APIKey{}`
  - `"httpAuthSecurityScheme"` → `%HTTPAuth{}`
  - `"oauth2SecurityScheme"` → `%OAuth2{}`
  - `"openIdConnectSecurityScheme"` → `%OpenIDConnect{}`
  - `"mtlsSecurityScheme"` → `%MutualTLS{}`
  """

  @type t ::
          __MODULE__.APIKey.t()
          | __MODULE__.HTTPAuth.t()
          | __MODULE__.OAuth2.t()
          | __MODULE__.OpenIDConnect.t()
          | __MODULE__.MutualTLS.t()
end

defmodule AshA2A.Protocol.SecurityScheme.APIKey do
  @moduledoc """
  API key security scheme.

  The key is sent via a header, query parameter, or cookie identified by `name`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          in: String.t(),
          description: String.t() | nil
        }

  @enforce_keys [:name, :in]
  defstruct [:name, :in, :description]
end

defmodule AshA2A.Protocol.SecurityScheme.HTTPAuth do
  @moduledoc """
  HTTP authentication security scheme (e.g. Bearer, Basic, Digest).
  """

  @type t :: %__MODULE__{
          scheme: String.t(),
          bearer_format: String.t() | nil,
          description: String.t() | nil
        }

  @enforce_keys [:scheme]
  defstruct [:scheme, :bearer_format, :description]
end

defmodule AshA2A.Protocol.SecurityScheme.OAuth2 do
  @moduledoc """
  OAuth 2.0 security scheme.
  """

  @type t :: %__MODULE__{
          flows: map(),
          oauth2_metadata_url: String.t() | nil,
          description: String.t() | nil
        }

  @enforce_keys [:flows]
  defstruct [:flows, :oauth2_metadata_url, :description]
end

defmodule AshA2A.Protocol.SecurityScheme.OpenIDConnect do
  @moduledoc """
  OpenID Connect security scheme.
  """

  @type t :: %__MODULE__{
          open_id_connect_url: String.t(),
          description: String.t() | nil
        }

  @enforce_keys [:open_id_connect_url]
  defstruct [:open_id_connect_url, :description]
end

defmodule AshA2A.Protocol.SecurityScheme.MutualTLS do
  @moduledoc """
  Mutual TLS (mTLS) security scheme.
  """

  @type t :: %__MODULE__{description: String.t() | nil}

  defstruct [:description]
end

defmodule AshA2A.Protocol.SecurityScheme.OAuthFlows do
  @moduledoc """
  Typed view and validation for the `OAuthFlows` oneof (a2a.proto `OAuthFlows`).

  `OAuth2.flows` stays a string-keyed wire map for backward compatibility. This
  module validates that map (`validate/1`: exactly one flow key, known keys only,
  per-flow member types, REQUIRED members of `deviceCode`) and converts to/from
  typed structs (`decode/1` is strict: every proto-REQUIRED member must be
  present; `encode/1` is its inverse).

  `implicit` and `password` are deprecated upstream: still decodable, and
  `deprecated?/1` flags them.
  """

  defmodule AuthorizationCode do
    @moduledoc false
    @enforce_keys [:authorization_url, :token_url, :scopes]
    defstruct [:authorization_url, :token_url, :refresh_url, :scopes, pkce_required: false]
  end

  defmodule ClientCredentials do
    @moduledoc false
    @enforce_keys [:token_url, :scopes]
    defstruct [:token_url, :refresh_url, :scopes]
  end

  defmodule DeviceCode do
    @moduledoc false
    @enforce_keys [:device_authorization_url, :token_url, :scopes]
    defstruct [:device_authorization_url, :token_url, :refresh_url, :scopes]
  end

  defmodule Implicit do
    @moduledoc false
    defstruct [:authorization_url, :refresh_url, scopes: %{}]
  end

  defmodule Password do
    @moduledoc false
    defstruct [:token_url, :refresh_url, scopes: %{}]
  end

  @type flow ::
          %AuthorizationCode{}
          | %ClientCredentials{}
          | %DeviceCode{}
          | %Implicit{}
          | %Password{}

  @keys ~w(authorizationCode clientCredentials deviceCode implicit password)
  @deprecated_flows ~w(implicit password)

  # key => {struct, [{wire, field, required?, type}]}
  @specs %{
    "authorizationCode" =>
      {AuthorizationCode,
       [
         {"authorizationUrl", :authorization_url, true, :string},
         {"tokenUrl", :token_url, true, :string},
         {"refreshUrl", :refresh_url, false, :string},
         {"scopes", :scopes, true, :scopes},
         {"pkceRequired", :pkce_required, false, :bool}
       ]},
    "clientCredentials" =>
      {ClientCredentials,
       [
         {"tokenUrl", :token_url, true, :string},
         {"refreshUrl", :refresh_url, false, :string},
         {"scopes", :scopes, true, :scopes}
       ]},
    "deviceCode" =>
      {DeviceCode,
       [
         {"deviceAuthorizationUrl", :device_authorization_url, true, :string},
         {"tokenUrl", :token_url, true, :string},
         {"refreshUrl", :refresh_url, false, :string},
         {"scopes", :scopes, true, :scopes}
       ]},
    "implicit" =>
      {Implicit,
       [
         {"authorizationUrl", :authorization_url, false, :string},
         {"refreshUrl", :refresh_url, false, :string},
         {"scopes", :scopes, false, :scopes}
       ]},
    "password" =>
      {Password,
       [
         {"tokenUrl", :token_url, false, :string},
         {"refreshUrl", :refresh_url, false, :string},
         {"scopes", :scopes, false, :scopes}
       ]}
  }

  @doc "Wire flow keys."
  def keys, do: @keys

  @doc "True when the wire flow key (or flows map) uses a deprecated flow."
  @spec deprecated?(String.t() | map()) :: boolean()
  def deprecated?(key) when is_binary(key), do: key in @deprecated_flows
  def deprecated?(%{} = flows), do: Enum.any?(Map.keys(flows), &(&1 in @deprecated_flows))

  @doc """
  Validates a wire flows map: exactly one known flow key, member types, and the
  REQUIRED members of `deviceCode`. Returns `{:ok, flows}` or `{:error, reason}`.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{} = flows) do
    case Map.keys(flows) do
      [key] when key in @keys -> validate_flow(key, flows[key], ["deviceCode"]) |> ret(flows)
      [key] -> {:error, {:unknown_flow, key}}
      [] -> {:error, {:invalid_field, "oauth2SecurityScheme.flows"}}
      keys -> {:error, {:oneof_violation, "oauth2SecurityScheme.flows", Enum.sort(keys)}}
    end
  end

  def validate(_), do: {:error, {:invalid_field, "oauth2SecurityScheme.flows"}}

  @doc "Strict decode of a wire flows map into a typed flow struct."
  @spec decode(term()) :: {:ok, flow()} | {:error, term()}
  def decode(%{} = flows) do
    with {:ok, _} <- validate(flows),
         [key] <- Map.keys(flows),
         :ok <- validate_flow(key, flows[key], Map.keys(@specs)) do
      {mod, spec} = Map.fetch!(@specs, key)

      fields =
        for {wire, field, _req, _t} <- spec, Map.has_key?(flows[key], wire) do
          {field, flows[key][wire]}
        end

      {:ok, struct(mod, fields)}
    end
  end

  def decode(other), do: validate(other)

  @doc "Encodes a typed flow struct to the wire flows map."
  @spec encode(flow()) :: map()
  def encode(%mod{} = flow) do
    {key, {_, spec}} = Enum.find(@specs, fn {_k, {m, _}} -> m == mod end)

    inner =
      for {wire, field, _req, _t} <- spec,
          value = Map.get(flow, field),
          value != nil,
          into: %{},
          do: {wire, value}

    %{key => inner}
  end

  defp ret(:ok, flows), do: {:ok, flows}
  defp ret({:error, _} = e, _), do: e

  defp validate_flow(key, %{} = inner, strict_for) do
    {_mod, spec} = Map.fetch!(@specs, key)
    known = Enum.map(spec, &elem(&1, 0))
    path = "oauth2SecurityScheme.flows.#{key}"

    with :ok <- check_unknown(inner, known, path) do
      Enum.reduce_while(spec, :ok, fn {wire, _f, required?, type}, :ok ->
        case Map.fetch(inner, wire) do
          :error ->
            if required? and key in strict_for,
              do: {:halt, {:error, {:missing_field, "#{path}.#{wire}"}}},
              else: {:cont, :ok}

          {:ok, v} ->
            if typed?(type, v),
              do: {:cont, :ok},
              else: {:halt, {:error, {:invalid_field, "#{path}.#{wire}"}}}
        end
      end)
    end
  end

  defp validate_flow(key, _other, _),
    do: {:error, {:invalid_field, "oauth2SecurityScheme.flows.#{key}"}}

  defp check_unknown(inner, known, path) do
    case Map.keys(inner) -- known do
      [] -> :ok
      [k | _] -> {:error, {:unknown_field, "#{path}.#{k}"}}
    end
  end

  defp typed?(:string, v), do: is_binary(v)
  defp typed?(:bool, v), do: is_boolean(v)

  defp typed?(:scopes, %{} = v),
    do: Enum.all?(v, fn {k, val} -> is_binary(k) and is_binary(val) end)

  defp typed?(:scopes, _), do: false
end
