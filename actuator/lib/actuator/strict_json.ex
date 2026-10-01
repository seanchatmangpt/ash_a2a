defmodule Actuator.StrictJson do
  @moduledoc """
  JSON decoding that refuses duplicate object keys.

  `Jason.decode/1` keeps the last of two equal keys, so two parsers (or a signer and the
  verifier) can disagree about the same bytes. Here any object with a repeated key, compared
  after unescaping (`"v"` equals `"\\u0076"`), at any depth, is `{:error, :duplicate_key}`;
  syntax errors are `{:error, :invalid_json}`.
  """

  @spec decode(binary()) :: {:ok, term()} | {:error, :duplicate_key | :invalid_json}
  def decode(bin) when is_binary(bin) do
    with {:ok, term} <- jason(bin),
         :ok <- no_dups(bin) do
      {:ok, term}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  defp jason(bin) do
    case Jason.decode(bin) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :invalid_json}
    end
  end

  # The input is already valid JSON, so the walk only tracks structure.
  defp no_dups(bin) do
    case value(ws(bin)) do
      {:error, _} = e -> e
      _rest -> :ok
    end
  catch
    :duplicate_key -> {:error, :duplicate_key}
  end

  defp value(<<"{", rest::binary>>), do: object(ws(rest), MapSet.new())
  defp value(<<"[", rest::binary>>), do: array(ws(rest))
  defp value(<<"\"", _::binary>> = s), do: elem(string(s), 1)
  defp value(bin), do: scalar(bin)

  defp object(<<"}", rest::binary>>, _seen), do: rest

  defp object(<<"\"", _::binary>> = s, seen) do
    {key, rest} = string(s)
    if MapSet.member?(seen, key), do: throw(:duplicate_key)
    <<":", rest::binary>> = ws(rest)
    rest = value(ws(rest)) |> ws()
    seen = MapSet.put(seen, key)

    case rest do
      <<",", r::binary>> -> object(ws(r), seen)
      <<"}", r::binary>> -> r
    end
  end

  defp array(<<"]", rest::binary>>), do: rest

  defp array(bin) do
    rest = value(bin) |> ws()

    case rest do
      <<",", r::binary>> -> array(ws(r))
      <<"]", r::binary>> -> r
    end
  end

  # returns {decoded_key, rest}
  defp string(<<"\"", rest::binary>> = s) do
    len = str_len(rest, 0)
    raw = binary_part(s, 0, len + 2)
    {Jason.decode!(raw), binary_part(rest, len + 1, byte_size(rest) - len - 1)}
  end

  defp str_len(<<"\\", _, r::binary>>, n), do: str_len(r, n + 2)
  defp str_len(<<"\"", _::binary>>, n), do: n
  defp str_len(<<_, r::binary>>, n), do: str_len(r, n + 1)

  defp scalar(bin), do: scalar_end(bin)

  defp scalar_end(<<c, _::binary>> = rest) when c in [?,, ?], ?}, ?\s, ?\t, ?\n, ?\r], do: rest
  defp scalar_end(<<_, r::binary>>), do: scalar_end(r)
  defp scalar_end(<<>>), do: <<>>

  defp ws(<<c, r::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: ws(r)
  defp ws(bin), do: bin
end
