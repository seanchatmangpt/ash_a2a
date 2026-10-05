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
          in: String.t()
        }

  @enforce_keys [:name, :in]
  defstruct [:name, :in]
end

defmodule AshA2A.Protocol.SecurityScheme.HTTPAuth do
  @moduledoc """
  HTTP authentication security scheme (e.g. Bearer, Basic, Digest).
  """

  @type t :: %__MODULE__{
          scheme: String.t()
        }

  @enforce_keys [:scheme]
  defstruct [:scheme]
end

defmodule AshA2A.Protocol.SecurityScheme.OAuth2 do
  @moduledoc """
  OAuth 2.0 security scheme.
  """

  @type t :: %__MODULE__{
          flows: map(),
          oauth2_metadata_url: String.t() | nil
        }

  @enforce_keys [:flows]
  defstruct [:flows, :oauth2_metadata_url]
end

defmodule AshA2A.Protocol.SecurityScheme.OpenIDConnect do
  @moduledoc """
  OpenID Connect security scheme.
  """

  @type t :: %__MODULE__{
          open_id_connect_url: String.t()
        }

  @enforce_keys [:open_id_connect_url]
  defstruct [:open_id_connect_url]
end

defmodule AshA2A.Protocol.SecurityScheme.MutualTLS do
  @moduledoc """
  Mutual TLS (mTLS) security scheme.
  """

  @type t :: %__MODULE__{}

  defstruct []
end
