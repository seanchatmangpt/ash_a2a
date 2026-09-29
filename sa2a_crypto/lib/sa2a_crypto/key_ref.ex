defmodule Sa2aCrypto.KeyRef do
  @moduledoc """
  Key identity: `kid` = base64url (no padding) of the first 16 bytes of
  `sha256(SPKI DER)`. ES256/EdDSA/ML-DSA/SLH-DSA use their standard SPKI; hybrid keys
  hash the concatenation of both component SPKIs.
  """
  alias Sa2aCrypto.Suite

  @p256_prefix Base.decode16!("3059301306072A8648CE3D020106082A8648CE3D030107034200")
  @ed_prefix Base.decode16!("302A300506032B6570032100")

  @oids %{
    "ML-DSA-44" => [2, 16, 840, 1, 101, 3, 4, 3, 17],
    "ML-DSA-65" => [2, 16, 840, 1, 101, 3, 4, 3, 18],
    "ML-DSA-87" => [2, 16, 840, 1, 101, 3, 4, 3, 19],
    "SLH-DSA-SHA2-128S" => [2, 16, 840, 1, 101, 3, 4, 3, 20],
    "SLH-DSA-SHA2-128F" => [2, 16, 840, 1, 101, 3, 4, 3, 21],
    "SLH-DSA-SHA2-192S" => [2, 16, 840, 1, 101, 3, 4, 3, 22],
    "SLH-DSA-SHA2-192F" => [2, 16, 840, 1, 101, 3, 4, 3, 23],
    "SLH-DSA-SHA2-256S" => [2, 16, 840, 1, 101, 3, 4, 3, 24],
    "SLH-DSA-SHA2-256F" => [2, 16, 840, 1, 101, 3, 4, 3, 25],
    "SLH-DSA-SHAKE-128S" => [2, 16, 840, 1, 101, 3, 4, 3, 26],
    "SLH-DSA-SHAKE-128F" => [2, 16, 840, 1, 101, 3, 4, 3, 27],
    "SLH-DSA-SHAKE-192S" => [2, 16, 840, 1, 101, 3, 4, 3, 28],
    "SLH-DSA-SHAKE-192F" => [2, 16, 840, 1, 101, 3, 4, 3, 29],
    "SLH-DSA-SHAKE-256S" => [2, 16, 840, 1, 101, 3, 4, 3, 30],
    "SLH-DSA-SHAKE-256F" => [2, 16, 840, 1, 101, 3, 4, 3, 31]
  }

  @spec spki(String.t(), term()) :: {:ok, binary()} | :error
  def spki("ES256", <<4, _::binary-size(64)>> = pub), do: {:ok, @p256_prefix <> pub}
  def spki("EdDSA", <<_::binary-size(32)>> = pub), do: {:ok, @ed_prefix <> pub}

  def spki(alg, pub) when is_binary(alg) and is_binary(pub) do
    case Map.fetch(@oids, alg) do
      {:ok, oid} ->
        algid = der(0x30, der(0x06, oid_body(oid)))
        {:ok, der(0x30, algid <> der(0x03, <<0>> <> pub))}

      :error ->
        :error
    end
  end

  def spki(alg, {cpub, ppub}) when is_binary(alg) do
    with {:ok, {c, p}} <- Suite.hybrid_parts(alg),
         {:ok, cs} <- spki(c, cpub),
         {:ok, ps} <- spki(p, ppub) do
      {:ok, cs <> ps}
    else
      _ -> :error
    end
  end

  def spki(_, _), do: :error

  @spec kid(String.t(), term()) :: {:ok, String.t()} | :error
  def kid(alg, pub) do
    with {:ok, spki} <- spki(alg, pub) do
      <<h::binary-size(16), _::binary>> = :crypto.hash(:sha256, spki)
      {:ok, Base.url_encode64(h, padding: false)}
    end
  end

  @doc "`kid/2` that raises on unsupported input (test/enrolment convenience)."
  def kid!(alg, pub) do
    {:ok, k} = kid(alg, pub)
    k
  end

  defp oid_body([a, b | rest]),
    do: <<a * 40 + b>> <> IO.iodata_to_binary(Enum.map(rest, &base128/1))

  defp base128(n) when n < 128, do: <<n>>

  defp base128(n) do
    bytes =
      Stream.unfold(n, fn
        0 -> nil
        x -> {rem(x, 128), div(x, 128)}
      end)
      |> Enum.reverse()

    {init, [last]} = Enum.split(bytes, -1)
    IO.iodata_to_binary(Enum.map(init, &<<Bitwise.bor(&1, 0x80)>>) ++ [<<last>>])
  end

  defp der(tag, body), do: <<tag>> <> der_len(byte_size(body)) <> body
  defp der_len(l) when l < 0x80, do: <<l>>
  defp der_len(l) when l < 0x100, do: <<0x81, l>>
  defp der_len(l), do: <<0x82, l::16>>
end
