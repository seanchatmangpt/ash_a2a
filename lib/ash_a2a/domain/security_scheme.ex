defmodule AshA2A.Domain.SecurityScheme do
  @moduledoc """
  One declared A2A security scheme (`security do security_scheme :name, :kind end`).

  Kinds and the fields each one reads (all other fields are ignored):

    * `:bearer` -- HTTP bearer; optional `bearer_format`.
    * `:api_key` -- `location` (`:header` default, `:query`, `:cookie`) and
      `param_name` (default `"X-API-Key"`).
    * `:http` -- generic HTTP auth; `http_scheme` (e.g. `"basic"`, `"bearer"`;
      required) and optional `bearer_format`.
    * `:oauth2` -- `oauth_flows`, a map keyed by flow name (`"authorizationCode"`,
      `"clientCredentials"`, `"deviceCode"`, ...) whose values are flow maps passed
      through to `AshA2A.Protocol.SecurityScheme`; `scopes` documents the scope names.
    * `:openid_connect` -- `openid_url` (required), the discovery URL.
    * `:mtls` -- mutual TLS; no further fields.
    * `:none` -- no scheme is projected onto the card.
  """

  defstruct [
    :name,
    :kind,
    :location,
    :param_name,
    :http_scheme,
    :bearer_format,
    :oauth_flows,
    :openid_url,
    :__identifier__,
    :__spark_metadata__,
    scopes: []
  ]

  @type kind :: :bearer | :api_key | :none | :http | :oauth2 | :openid_connect | :mtls

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          location: :header | :query | :cookie | nil,
          param_name: String.t() | nil,
          http_scheme: String.t() | nil,
          bearer_format: String.t() | nil,
          oauth_flows: map() | nil,
          scopes: [String.t()],
          openid_url: String.t() | nil,
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }
end
