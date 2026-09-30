defmodule Sa2aCrypto.SignedMessage do
  @moduledoc """
  Domain-separated signed message (RFC-SA2A-007 E-E):

      "SA2A-C2-APPROVAL-v1" <> <<0>> <> JCS({v, alg, kid, effect_digest, principal,
        policy_epoch, revocation_epoch, generation, nonce, not_before, expires, audience})

  `build/1` refuses floats, integers outside +/-(2^53-1), duplicate or atom-vs-string
  key collisions, non-UTF-8 strings, unsupported values, unknown or missing fields,
  input deeper than #{8} levels, and encodings over 16 KiB.
  """

  @domain "SA2A-C2-APPROVAL-v1"
  @max_int 9_007_199_254_740_991
  @max_depth 8
  @max_nodes 2048
  @max_bytes 16_384
  @fields ~w(v alg kid effect_digest principal policy_epoch revocation_epoch generation
             nonce not_before expires audience)

  def domain, do: @domain
  def prefix, do: @domain <> <<0>>
  def fields, do: @fields
  def max_int, do: @max_int

  @spec build(map()) :: {:ok, binary()} | {:error, atom()}
  def build(fields) when is_map(fields) do
    with {:ok, obj} <- normalize(fields),
         :ok <- check_fields(obj),
         {:ok, json} <- encode(obj) do
      {:ok, prefix() <> json}
    end
  end

  def build(_), do: {:error, :not_an_object}

  @doc "Normalize an arbitrary JSON-shaped term (string keys) under the signed-object rules."
  @spec normalize(term()) :: {:ok, map()} | {:error, atom()}
  def normalize(term) do
    case walk(term, 0, 0) do
      {:ok, v, _n} when is_map(v) -> {:ok, v}
      {:ok, _, _} -> {:error, :not_an_object}
      {:error, _} = e -> e
    end
  end

  defp walk(_, depth, _n) when depth > @max_depth, do: {:error, :too_deep}
  defp walk(_, _, n) when n > @max_nodes, do: {:error, :oversize}
  defp walk(v, _, n) when is_float(v), do: reject(v, :float_not_allowed, n)

  defp walk(v, _, n) when is_integer(v) do
    if abs(v) <= @max_int, do: {:ok, v, n + 1}, else: {:error, :integer_out_of_range}
  end

  defp walk(v, _, n) when is_binary(v) do
    if String.valid?(v), do: {:ok, v, n + 1}, else: {:error, :invalid_string}
  end

  defp walk(v, _, n) when is_boolean(v) or is_nil(v), do: {:ok, v, n + 1}

  defp walk(v, depth, n) when is_list(v) do
    Enum.reduce_while(v, {:ok, [], n + 1}, fn el, {:ok, acc, n} ->
      case walk(el, depth + 1, n) do
        {:ok, x, n2} -> {:cont, {:ok, [x | acc], n2}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc, n} -> {:ok, Enum.reverse(acc), n}
      e -> e
    end
  end

  defp walk(v, depth, n) when is_map(v) and not is_struct(v) do
    Enum.reduce_while(v, {:ok, %{}, n + 1}, fn {k, val}, {:ok, acc, n} ->
      with {:ok, key} <- key(k),
           false <- Map.has_key?(acc, key),
           {:ok, x, n2} <- walk(val, depth + 1, n + 1) do
        {:cont, {:ok, Map.put(acc, key, x), n2}}
      else
        true -> {:halt, {:error, :duplicate_key}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp walk(_, _, _), do: {:error, :unsupported_value}

  defp reject(_, code, _), do: {:error, code}

  defp key(k) when is_binary(k),
    do: if(String.valid?(k), do: {:ok, k}, else: {:error, :invalid_string})

  defp key(k) when is_atom(k) and not is_nil(k) and not is_boolean(k),
    do: {:ok, Atom.to_string(k)}

  defp key(_), do: {:error, :unsupported_key}

  defp check_fields(obj) do
    keys = Map.keys(obj)

    cond do
      Enum.any?(@fields, &(not Map.has_key?(obj, &1))) -> {:error, :missing_field}
      Enum.any?(keys, &(&1 not in @fields)) -> {:error, :unknown_field}
      not typed?(obj) -> {:error, :bad_field_type}
      true -> :ok
    end
  end

  defp typed?(o) do
    Enum.all?(~w(alg kid effect_digest nonce audience), &is_binary(o[&1])) and
      Enum.all?(~w(v policy_epoch revocation_epoch generation not_before expires), fn f ->
        is_integer(o[f]) and o[f] >= 0
      end) and not is_nil(o["principal"])
  end

  defp encode(obj) do
    json = Jcs.encode(obj)
    if byte_size(json) <= @max_bytes, do: {:ok, json}, else: {:error, :oversize}
  rescue
    _ -> {:error, :canonical_unencodable}
  end

  @doc "Strip the domain prefix and decode the signed object; refuses a wrong domain string."
  @spec parse(binary()) :: {:ok, map()} | {:error, :bad_domain | :malformed_message}
  def parse(bytes) when is_binary(bytes) do
    pre = prefix()
    n = byte_size(pre)

    case bytes do
      <<^pre::binary-size(^n), json::binary>> ->
        case Sa2aCrypto.StrictJson.decode(json) do
          {:ok, m} when is_map(m) -> {:ok, m}
          _ -> {:error, :malformed_message}
        end

      _ ->
        {:error, :bad_domain}
    end
  end

  def parse(_), do: {:error, :malformed_message}

  @doc "`sha256:<hex>` digest of message bytes."
  def digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
