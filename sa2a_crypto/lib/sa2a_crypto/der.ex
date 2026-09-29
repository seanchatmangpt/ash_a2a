defmodule Sa2aCrypto.DER do
  @moduledoc """
  Strict X9.62 ECDSA-Sig-Value DER validation for P-256 (RFC-SA2A-007 E-E):
  single canonical encoding, minimal lengths, no trailing bytes, no negative or
  zero-padded integers, `r` and `s` in `1..n-1`. High-s is NOT rejected.
  """
  import Bitwise

  @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @doc "Group order of P-256."
  def n, do: @n

  @spec parse_ecdsa_sig(binary()) :: {:ok, {pos_integer(), pos_integer()}} | {:error, atom()}
  def parse_ecdsa_sig(<<0x30, rest::binary>>) do
    with {:ok, len, body} <- read_len(rest),
         :ok <- exact(byte_size(body), len),
         {:ok, r, body} <- read_int(body),
         {:ok, s, body} <- read_int(body),
         :ok <- if(body == <<>>, do: :ok, else: {:error, :trailing_bytes}) do
      {:ok, {r, s}}
    end
  end

  def parse_ecdsa_sig(_), do: {:error, :bad_der}

  defp exact(a, a), do: :ok
  defp exact(a, b) when a > b, do: {:error, :trailing_bytes}
  defp exact(_, _), do: {:error, :truncated}

  defp read_len(<<l, rest::binary>>) when l < 0x80, do: {:ok, l, rest}
  defp read_len(<<0x81, l, rest::binary>>) when l >= 0x80, do: {:ok, l, rest}
  defp read_len(<<0x81, _, _::binary>>), do: {:error, :non_minimal_length}
  defp read_len(_), do: {:error, :bad_der}

  defp read_int(<<0x02, rest::binary>>) do
    with {:ok, len, rest} <- read_len(rest),
         true <- len >= 1 or {:error, :bad_der},
         true <- byte_size(rest) >= len or {:error, :truncated} do
      <<v::binary-size(^len), tail::binary>> = rest

      with :ok <- check_minimal(v) do
        i = :binary.decode_unsigned(v)
        if i >= 1 and i < @n, do: {:ok, i, tail}, else: {:error, :out_of_range}
      end
    end
  end

  defp read_int(_), do: {:error, :bad_der}

  defp check_minimal(<<b, _::binary>>) when band(b, 0x80) != 0, do: {:error, :negative_integer}

  defp check_minimal(<<0, b, _::binary>>) when band(b, 0x80) == 0,
    do: {:error, :non_minimal_integer}

  defp check_minimal(_), do: :ok

  @doc "Encode `{r, s}` as minimal DER (test/vector helper)."
  @spec encode_ecdsa_sig(non_neg_integer(), non_neg_integer()) :: binary()
  def encode_ecdsa_sig(r, s) do
    body = enc_int(r) <> enc_int(s)
    <<0x30>> <> enc_len(byte_size(body)) <> body
  end

  defp enc_int(i) do
    b = :binary.encode_unsigned(i)
    b = if band(:binary.first(b), 0x80) != 0, do: <<0>> <> b, else: b
    <<0x02>> <> enc_len(byte_size(b)) <> b
  end

  defp enc_len(l) when l < 0x80, do: <<l>>
  defp enc_len(l), do: <<0x81, l>>
end
