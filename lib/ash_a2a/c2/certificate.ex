defmodule AshA2A.C2.Certificate do
  @moduledoc """
  Canonical actuation certificate model of the C2 control plane (docs/reference/c2-certificate.md).

  Field names follow the control-plane wire (`AshA2A.C2.Wire`): `version`, `not_before_ms`,
  `expires_at_ms`, `threshold`, `audience`, `nonce`. Two optional fields, `alg` and `kid`, are
  certificate-level fall-backs for a signature entry that omits its own.

  `signatures` is a list of `%{signer, kid, alg, nonce, signature}` maps (`signature` is raw
  bytes; on the wire it is base64url). `kid`, `alg` and `nonce` fall back to the certificate-level
  fields when an entry omits them. The signed bytes are rebuilt by the verifier
  (`AshA2A.C2.CertificateVerifier`) from durable state; nothing here is trusted as-is.

  ## Time representation (decision)

  The struct carries integer **milliseconds** (control-plane wire). The signed message defined by
  `Sa2aCrypto.SignedMessage` (RFC-SA2A-007 E-E) binds `not_before` and `expires` as integer unix
  **seconds** (the same integers the actuator's certificate JSON and the authority service mint;
  no RFC 3339 string form exists in any of the three deployed projects). The conversion is
  explicit and lossless-or-refused: `to_seconds/1` accepts only whole-second millisecond values
  and returns `{:error, :sub_second_time}` otherwise, because truncating a validity bound would
  silently change what was signed. `from_seconds/1` is `seconds * 1000`.
  """
  @enforce_keys [
    :version,
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :nonce,
    :not_before_ms,
    :expires_at_ms,
    :audience,
    :threshold,
    :signatures
  ]
  defstruct @enforce_keys ++ [:alg, :kid]

  @max_seconds 9_007_199_254_740_991

  @doc """
  Decode a certificate from wire JSON bytes (or an already-decoded wire map). Duplicate JSON
  object keys at any depth are refused with `{:error, :duplicate_json_key}`.
  """
  @spec decode(binary() | map()) ::
          {:ok, t()} | {:error, :duplicate_json_key | :invalid_certificate_wire}
  def decode(json_or_wire) when is_binary(json_or_wire) or is_map(json_or_wire),
    do: AshA2A.C2.Wire.decode_certificate(json_or_wire)

  def decode(_), do: {:error, :invalid_certificate_wire}

  def bound?(c, e), do: c.effect_digest == e.digest and c.principal == e.principal

  @doc "Milliseconds to the whole unix seconds the signed message binds; refuses sub-second values."
  @spec to_seconds(term()) :: {:ok, non_neg_integer()} | {:error, :sub_second_time | :bad_time}
  def to_seconds(ms) when is_integer(ms) and ms >= 0 do
    if rem(ms, 1000) == 0, do: {:ok, div(ms, 1000)}, else: {:error, :sub_second_time}
  end

  def to_seconds(_), do: {:error, :bad_time}

  @doc "Unix seconds (signed-message form) to the struct's millisecond form."
  @spec from_seconds(non_neg_integer()) :: non_neg_integer()
  def from_seconds(s) when is_integer(s) and s >= 0 and s <= @max_seconds, do: s * 1000

  @doc "`{not_before, expires}` in signed-message seconds, or the conversion refusal."
  @spec window_seconds(%__MODULE__{}) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, atom()}
  def window_seconds(%__MODULE__{not_before_ms: nb, expires_at_ms: ex}) do
    with {:ok, a} <- to_seconds(nb), {:ok, b} <- to_seconds(ex), do: {:ok, {a, b}}
  end

  @type t :: %__MODULE__{
          version: pos_integer(),
          effect_digest: binary(),
          principal: term(),
          policy_epoch: non_neg_integer(),
          revocation_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          nonce: binary(),
          not_before_ms: non_neg_integer(),
          expires_at_ms: pos_integer(),
          audience: binary(),
          threshold: pos_integer(),
          signatures: list(),
          alg: binary() | nil,
          kid: binary() | nil
        }
end
