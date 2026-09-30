defmodule Sa2aCrypto.Envelope do
  @moduledoc """
  SignatureEnvelope `{v, alg, kid, profile, signed_bytes_digest, signature, nonce,
  not_before, expires, audience}`; wire form is JCS with `signature` base64url (no padding).
  """
  alias Sa2aCrypto.Suite

  @enforce_keys [
    :v,
    :alg,
    :kid,
    :profile,
    :signed_bytes_digest,
    :signature,
    :nonce,
    :not_before,
    :expires,
    :audience
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
  @profiles %{"classical" => :classical, "hybrid" => :hybrid, "pqc" => :pqc}
  @keys ~w(v alg kid profile signed_bytes_digest signature nonce not_before expires audience)

  @doc "Build from a map with atom or string keys (signature raw bytes when atom-keyed struct input)."
  @spec from_map(map()) :: {:ok, t()} | {:error, :malformed_envelope}
  def from_map(%__MODULE__{} = e), do: {:ok, e}

  def from_map(m) when is_map(m) do
    g = fn k -> Map.get(m, k, Map.get(m, String.to_atom(k))) end

    with true <- Enum.all?(@keys, &(g.(&1) != nil)),
         true <- map_size(m) == length(@keys),
         profile when profile in [:classical, :hybrid, :pqc] <- profile(g.("profile")),
         true <- is_integer(g.("v")),
         true <-
           Enum.all?(~w(alg kid signed_bytes_digest signature nonce audience), &is_binary(g.(&1))),
         true <- is_integer(g.("not_before")) and is_integer(g.("expires")) do
      {:ok,
       %__MODULE__{
         v: g.("v"),
         alg: g.("alg"),
         kid: g.("kid"),
         profile: profile,
         signed_bytes_digest: g.("signed_bytes_digest"),
         signature: g.("signature"),
         nonce: g.("nonce"),
         not_before: g.("not_before"),
         expires: g.("expires"),
         audience: g.("audience")
       }}
    else
      _ -> {:error, :malformed_envelope}
    end
  end

  def from_map(_), do: {:error, :malformed_envelope}

  defp profile(p) when p in [:classical, :hybrid, :pqc], do: p
  defp profile(p) when is_binary(p), do: Map.get(@profiles, p)
  defp profile(_), do: nil

  @spec encode(t()) :: {:ok, binary()} | {:error, :malformed_envelope}
  def encode(%__MODULE__{} = e) do
    {:ok,
     Jcs.encode(%{
       "v" => e.v,
       "alg" => e.alg,
       "kid" => e.kid,
       "profile" => Atom.to_string(e.profile),
       "signed_bytes_digest" => e.signed_bytes_digest,
       "signature" => Base.url_encode64(e.signature, padding: false),
       "nonce" => e.nonce,
       "not_before" => e.not_before,
       "expires" => e.expires,
       "audience" => e.audience
     })}
  rescue
    _ -> {:error, :malformed_envelope}
  end

  def encode(_), do: {:error, :malformed_envelope}

  @doc "Decode wire JSON. `signature` stays base64url text until `signature_bytes/1`."
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed_envelope}
  def decode(json) when is_binary(json) do
    with {:ok, m} when is_map(m) <- Sa2aCrypto.StrictJson.decode(json),
         {:ok, e} <- from_map(m),
         {:ok, sig} <- b64(e.signature) do
      {:ok, %{e | signature: sig}}
    else
      _ -> {:error, :malformed_envelope}
    end
  end

  def decode(_), do: {:error, :malformed_envelope}

  @doc "Strict base64url (no padding, canonical)."
  def b64(s) when is_binary(s) do
    with {:ok, bin} <- Base.url_decode64(s, padding: false),
         true <- Base.url_encode64(bin, padding: false) == s do
      {:ok, bin}
    else
      _ -> :error
    end
  end

  @doc "Replay key: `(kid, nonce)`; never signature bytes (ECDSA is malleable)."
  def replay_key(%__MODULE__{kid: k, nonce: n}), do: {k, n}

  @doc false
  def profile_matches_alg?(%__MODULE__{alg: alg, profile: p}), do: Suite.profile_of(alg) == p
end
