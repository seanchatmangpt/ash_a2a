defmodule Sa2aCrypto.Native do
  @moduledoc """
  Provider backed by OTP `:crypto` (verified on OTP 29.1.1, crypto-5.10).

  Suites: `ES256` (P-256/SHA-256, strict X9.62 DER), `EdDSA` (Ed25519), ML-DSA-44/65/87
  and SLH-DSA-* via the OTP atoms, and hybrid `"<classical>+<pqc>"` (both components
  must verify; hybrid signature = `<<len1::32, sig1::binary, sig2::binary>>`, hybrid
  public key = `{classical_pub, pqc_pub}`).

  PQ suites whose atom is absent from `:crypto.supports(:public_keys)` fail closed with
  `{:error, :provider_required}`. Malformed keys return `{:error, :bad_key}`; nothing
  here raises on attacker-controlled input.
  """
  @behaviour Sa2aCrypto.Provider

  alias Sa2aCrypto.{DER, Suite}

  @p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  @p256_spki_prefix Base.decode16!("3059301306072A8648CE3D020106082A8648CE3D030107034200")
  @ed_spki_prefix Base.decode16!("302A300506032B6570032100")

  @pk_sizes %{
    mldsa44: 1312,
    mldsa65: 1952,
    mldsa87: 2592,
    slh_dsa_sha2_128s: 32,
    slh_dsa_sha2_128f: 32,
    slh_dsa_shake_128s: 32,
    slh_dsa_shake_128f: 32,
    slh_dsa_sha2_192s: 48,
    slh_dsa_sha2_192f: 48,
    slh_dsa_shake_192s: 48,
    slh_dsa_shake_192f: 48,
    slh_dsa_sha2_256s: 64,
    slh_dsa_sha2_256f: 64,
    slh_dsa_shake_256s: 64,
    slh_dsa_shake_256f: 64
  }

  @impl true
  def supports?(alg) do
    case Suite.profile_of(alg) do
      :classical ->
        true

      :pqc ->
        pq_available?(Suite.pq_atom(alg))

      :hybrid ->
        {:ok, {c, p}} = Suite.hybrid_parts(alg)
        supports?(c) and supports?(p)

      nil ->
        false
    end
  end

  @doc "Is the OTP crypto atom present on this runtime?"
  def pq_available?(atom) when is_atom(atom) and not is_nil(atom) do
    atom in :crypto.supports(:public_keys)
  rescue
    _ -> false
  end

  def pq_available?(_), do: false

  @impl true
  def verify("ES256", msg, sig, pub) when is_binary(msg) and is_binary(sig) do
    with {:ok, point} <- p256_point(pub),
         {:ok, _} <- DER.parse_ecdsa_sig(sig) |> der_result() do
      safe_verify(fn -> :crypto.verify(:ecdsa, :sha256, msg, sig, [point, :secp256r1]) end)
    end
  end

  def verify("EdDSA", msg, sig, pub) when is_binary(msg) and is_binary(sig) do
    with {:ok, key} <- ed_key(pub),
         :ok <- if(byte_size(sig) == 64, do: :ok, else: {:error, :bad_signature}) do
      safe_verify(fn -> :crypto.verify(:eddsa, :none, msg, sig, [key, :ed25519]) end)
    end
  end

  def verify(alg, msg, sig, pub) when is_binary(alg) and is_binary(msg) and is_binary(sig) do
    case Suite.profile_of(alg) do
      :pqc -> verify_pq(alg, msg, sig, pub)
      :hybrid -> verify_hybrid(alg, msg, sig, pub)
      _ -> {:error, :unsupported_algorithm}
    end
  end

  def verify(_, _, _, _), do: {:error, :bad_signature}

  defp der_result({:ok, v}), do: {:ok, v}
  defp der_result({:error, _}), do: {:error, :bad_signature}

  defp verify_pq(alg, msg, sig, pub) do
    atom = Suite.pq_atom(alg)

    cond do
      not pq_available?(atom) -> {:error, :provider_required}
      not (is_binary(pub) and byte_size(pub) == Map.fetch!(@pk_sizes, atom)) -> {:error, :bad_key}
      true -> safe_verify(fn -> :crypto.verify(atom, :none, msg, sig, pub) end)
    end
  end

  defp verify_hybrid(alg, msg, sig, {cpub, ppub}) do
    with {:ok, {c, p}} <- Suite.hybrid_parts(alg) |> tag(:unsupported_algorithm),
         :ok <- if(supports?(alg), do: :ok, else: {:error, :provider_required}),
         {:ok, {csig, psig}} <- split_hybrid(sig),
         :ok <- verify(c, msg, csig, cpub),
         :ok <- verify(p, msg, psig, ppub) do
      :ok
    end
  end

  defp verify_hybrid(_, _, _, _), do: {:error, :bad_key}

  defp tag(:error, e), do: {:error, e}
  defp tag(ok, _), do: ok

  defp split_hybrid(<<l::32, csig::binary-size(l), psig::binary>>) when psig != <<>>,
    do: {:ok, {csig, psig}}

  defp split_hybrid(_), do: {:error, :bad_signature}

  @doc "Frame a hybrid signature."
  def join_hybrid(csig, psig), do: <<byte_size(csig)::32, csig::binary, psig::binary>>

  defp safe_verify(fun) do
    case fun.() do
      true -> :ok
      _ -> {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :bad_signature}
  catch
    _, _ -> {:error, :bad_signature}
  end

  # ---- key normalization -------------------------------------------------

  @doc "Normalize a P-256 public key (raw uncompressed point or SPKI DER); validates curve membership."
  @spec p256_point(term()) :: {:ok, <<_::520>>} | {:error, :bad_key}
  def p256_point(<<@p256_spki_prefix, point::binary-size(65)>>), do: p256_point(point)

  def p256_point(<<4, x::binary-size(32), y::binary-size(32)>> = point) do
    xi = :binary.decode_unsigned(x)
    yi = :binary.decode_unsigned(y)

    if xi < @p and yi < @p and rem(yi * yi - xi * xi * xi + 3 * xi - @b, @p) == 0,
      do: {:ok, point},
      else: {:error, :bad_key}
  end

  def p256_point(_), do: {:error, :bad_key}

  @doc "Normalize an Ed25519 public key (raw 32 bytes or SPKI DER)."
  def ed_key(<<@ed_spki_prefix, key::binary-size(32)>>), do: {:ok, key}
  def ed_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}
  def ed_key(_), do: {:error, :bad_key}

  # ---- signing (tests, enrolment tooling; verifiers never call this) -----

  @impl true
  def sign("ES256", msg, priv) when is_binary(priv),
    do: safe_sign(fn -> :crypto.sign(:ecdsa, :sha256, msg, [priv, :secp256r1]) end)

  def sign("EdDSA", msg, priv) when is_binary(priv),
    do: safe_sign(fn -> :crypto.sign(:eddsa, :none, msg, [priv, :ed25519]) end)

  def sign(alg, msg, priv) when is_binary(alg) do
    case Suite.profile_of(alg) do
      :pqc ->
        atom = Suite.pq_atom(alg)

        if pq_available?(atom),
          do: safe_sign(fn -> :crypto.sign(atom, :none, msg, priv) end),
          else: {:error, :provider_required}

      :hybrid ->
        with {:ok, {c, p}} <- Suite.hybrid_parts(alg) |> tag(:unsupported_algorithm),
             {cpriv, ppriv} <- priv || {:error, :bad_key},
             {:ok, cs} <- sign(c, msg, cpriv),
             {:ok, ps} <- sign(p, msg, ppriv) do
          {:ok, join_hybrid(cs, ps)}
        else
          {:error, _} = e -> e
          _ -> {:error, :bad_key}
        end

      _ ->
        {:error, :unsupported_algorithm}
    end
  end

  defp safe_sign(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :bad_key}
  end
end
