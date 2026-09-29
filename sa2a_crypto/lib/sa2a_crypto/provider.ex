defmodule Sa2aCrypto.Provider do
  @moduledoc """
  Provider behaviour. SA2A never calls algorithms directly; it consumes standing
  from a provider. `verify/4` is required; `sign/3` is optional (verifiers and
  registries never hold private keys).

  `alg` is a registry suite id (`"ES256"`, `"EdDSA"`, `"ML-DSA-65"`, hybrid
  `"ES256+ML-DSA-65"`, ...). Failures are typed: `:bad_signature`, `:bad_key`,
  `:provider_required` (suite registered but not available in this provider),
  `:unsupported_algorithm` (suite not registered).
  """

  @type error :: :bad_signature | :bad_key | :provider_required | :unsupported_algorithm

  @callback supports?(alg :: String.t()) :: boolean()
  @callback verify(
              alg :: String.t(),
              message :: binary(),
              signature :: binary(),
              public_key :: term()
            ) :: :ok | {:error, error()}
  @callback sign(alg :: String.t(), message :: binary(), private_key :: term()) ::
              {:ok, binary()} | {:error, error()}

  @optional_callbacks sign: 3
end
