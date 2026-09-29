defmodule Sa2aCrypto.Registry.Spki do
  @moduledoc """
  Decodes a stored `spki_der` back to the registry `public_key` term for `alg`.

  Strict: the decoded key MUST re-encode (via `Sa2aCrypto.KeyRef.spki/2`) to the identical
  DER, so a non-canonical or wrong-size encoding is refused, never raised on.
  """
  alias Sa2aCrypto.{KeyRef, Suite}

  @spec decode(String.t(), binary()) :: {:ok, term()} | {:error, :bad_key}
  def decode(alg, der) when is_binary(alg) and is_binary(der) do
    with {:ok, pub} <- extract(alg, der),
         {:ok, ^der} <- KeyRef.spki(alg, pub) do
      {:ok, pub}
    else
      _ -> {:error, :bad_key}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  def decode(_, _), do: {:error, :bad_key}

  defp extract(alg, der) do
    case Suite.hybrid_parts(alg) do
      {:ok, {c, p}} ->
        with {:ok, first, rest} <- split(der),
             {:ok, cpub} <- extract(c, first),
             {:ok, ppub} <- extract(p, rest) do
          {:ok, {cpub, ppub}}
        end

      :error ->
        single(alg, der)
    end
  end

  # SPKI ::= SEQUENCE { SEQUENCE { OID .. }, BIT STRING (0 unused bits, key) }
  defp single(_alg, der) do
    with {:ok, 0x30, body, <<>>} <- tlv(der),
         {:ok, 0x30, _algid, rest} <- tlv(body),
         {:ok, 0x03, <<0, key::binary>>, <<>>} <- tlv(rest) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp split(der) do
    with {:ok, 0x30, _body, rest} <- tlv(der) do
      first_size = byte_size(der) - byte_size(rest)
      <<first::binary-size(^first_size), _::binary>> = der
      {:ok, first, rest}
    else
      _ -> :error
    end
  end

  defp tlv(<<tag, l, rest::binary>>) when l < 0x80, do: body(tag, l, rest)
  defp tlv(<<tag, 0x81, l, rest::binary>>) when l >= 0x80, do: body(tag, l, rest)
  defp tlv(<<tag, 0x82, l::16, rest::binary>>) when l >= 0x100, do: body(tag, l, rest)
  defp tlv(_), do: :error

  defp body(tag, l, rest) when byte_size(rest) >= l do
    <<b::binary-size(^l), tail::binary>> = rest
    {:ok, tag, b, tail}
  end

  defp body(_, _, _), do: :error
end
