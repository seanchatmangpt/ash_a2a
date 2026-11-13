defmodule AshA2A.Attestation.Key do
  @moduledoc """
  Local asymmetric signing for Article-10 ingress attestation tokens.

  No JOSE library is declared in this repo's `mix.exs` deps, so this module
  implements a compact JWS-style token directly on top of the Erlang stdlib
  `:crypto` application:

  - Algorithm: ECDSA P-256 (`:prime256v1`) with SHA-256 (`ES256` in JOSE terms).
  - Key format: `%{priv: der, pub: der, curve: :prime256v1}` (ASN.1 DER, as
    produced/consumed by `:crypto.generate_key/2`, `:crypto.sign/4`,
    `:crypto.verify/5`).
  - Token format: `"v1.<base64url(json payload)>.<base64url(der signature)>"`
    — the ES256 compact-serialization shape (header algorithm is implied by
    the `v1` prefix rather than a JOSE header segment, since we produce and
    consume only our own tokens).

  This module owns the cryptographic primitives only. Claim-level policy
  (emulator detection, freshness, sensor metadata consistency) lives in
  `AshA2A.Attestation.Gate`.
  """

  @curve :prime256v1
  @prefix "v1"

  # P-256 group order n. ECDSA signatures are malleable: (r, s) and
  # (r, n - s) both verify. We enforce the canonical low-s form (s <= n/2)
  # at verify time, so a malleated twin of a legitimately-signed token is
  # refused as `:non_canonical_signature` rather than accepted as a fresh
  # signature.
  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @half_n div(@n, 2)

  @type key :: %{
          required(:priv) => binary(),
          required(:pub) => binary(),
          optional(any()) => any()
        }
  @type token :: binary()

  @doc """
  Generates a fresh ECDSA P-256 keypair as DER-encoded `%{priv:, pub:, curve:}`.
  """
  @spec generate() :: key()
  def generate do
    {pub, priv} = :crypto.generate_key(:ecdh, @curve)
    %{priv: priv, pub: pub, curve: @curve}
  end

  @doc """
  Signs `payload` (any term serializable to JSON) with `key`, returning a
  compact `v1.` token.
  """
  @spec sign(map(), key()) :: token() | {:error, term()}
  def sign(payload, %{priv: priv} = _key) when is_map(payload) do
    with {:ok, json} <- Jason.encode(payload),
         sig when is_binary(sig) <- safe_sign(json, priv),
         sig <- to_low_s(sig) do
      [@prefix, b64(json), b64(sig)] |> Enum.join(".")
    else
      {:error, reason} -> {:error, reason}
      :bad_key -> {:error, :bad_key}
      other -> {:error, {:sign_failed, other}}
    end
  end

  def sign(_payload, _key), do: {:error, :bad_key}

  defp safe_sign(json, priv) do
    :crypto.sign(:ecdsa, :sha256, json, [priv, @curve])
  rescue
    _ -> :bad_key
  end

  @doc """
  Verifies a `v1.` token against a public key.

  Returns `{:ok, claims}` (the decoded payload map) or
  `{:error, :bad_signature | :non_canonical_signature | :malformed_token}`.

  Signatures must be canonical low-s form (`s <= n/2`): the malleated twin
  `(r, n - s)` of a valid signature is refused with `:non_canonical_signature`
  before crypto verification.
  """
  @spec verify(token(), key()) ::
          {:ok, map()} | {:error, :bad_signature | :non_canonical_signature | :malformed_token}
  def verify(token, %{pub: pub} = _key) when is_binary(token) do
    case String.split(token, ".", parts: 3) do
      [@prefix, b64_payload, b64_sig] ->
        with {:ok, json} <- decode(b64_payload),
             {:ok, sig} <- decode(b64_sig),
             :ok <- canonical_low_s?(sig),
             true <- safe_verify(json, sig, pub),
             {:ok, claims} when is_map(claims) <- Jason.decode(json) do
          {:ok, claims}
        else
          false -> {:error, :bad_signature}
          {:error, :bad_signature} = err -> err
          {:error, :non_canonical_signature} = err -> err
          _ -> {:error, :malformed_token}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  def verify(_token, _key), do: {:error, :malformed_token}

  # --- low-s canonical form ---

  # DER ECDSA signature: SEQUENCE { INTEGER r, INTEGER s }. Structurally
  # broken signature bytes keep the historical :bad_signature; only a
  # well-formed DER with s > n/2 (a malleated twin) is :non_canonical_signature.
  @spec canonical_low_s?(binary()) :: :ok | {:error, :non_canonical_signature | :bad_signature}
  defp canonical_low_s?(der) when is_binary(der) do
    case parse_der_sig(der) do
      {:ok, s} when s <= @half_n -> :ok
      {:ok, _s} -> {:error, :non_canonical_signature}
      :error -> {:error, :bad_signature}
    end
  end

  defp canonical_low_s?(_), do: {:error, :bad_signature}

  # Sign-time normalization: :crypto.sign emits a random s, which is high
  # (s > n/2) about half the time. Since verify enforces canonical low-s,
  # every emitted signature is normalized to its low-s twin here so
  # sign/verify round-trips are deterministic.
  @spec to_low_s(binary()) :: binary()
  defp to_low_s(der) do
    with {:ok, body} <- split_der(der),
         {:ok, r_bin, s} <- parse_ints(body) do
      if s <= @half_n do
        der
      else
        s2_bin = der_int(@n - s)
        body2 = <<0x02, byte_size(r_bin), r_bin::binary, 0x02, byte_size(s2_bin), s2_bin::binary>>
        <<0x30, byte_size(body2), body2::binary>>
      end
    else
      _ -> der
    end
  end

  defp split_der(<<0x30, len, body::binary-size(len), _rest::binary>>), do: {:ok, body}
  defp split_der(_), do: :error

  defp parse_ints(<<0x02, rlen, r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>>),
    do: {:ok, r, :binary.decode_unsigned(s)}

  defp parse_ints(_), do: :error

  defp der_int(v) do
    bin = :binary.encode_unsigned(v)

    case bin do
      <<first, _::binary>> when first >= 128 -> <<0, bin::binary>>
      _ -> bin
    end
  end

  defp parse_der_sig(<<0x30, len, body::binary-size(len), _rest::binary>>) do
    with <<0x02, rlen, _r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>> <- body do
      {:ok, :binary.decode_unsigned(s)}

      # (r is length-checked but otherwise unused: canonicality is s-only)
    else
      _ -> :error
    end
  end

  defp parse_der_sig(_), do: :error

  defp safe_verify(json, sig, pub) do
    :crypto.verify(:ecdsa, :sha256, json, sig, [pub, @curve])
  rescue
    _ -> false
  end

  defp b64(data), do: Base.url_encode64(data, padding: false)
  defp decode(data), do: Base.url_decode64(data, padding: false)
end
