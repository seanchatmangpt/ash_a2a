defmodule AshA2A.Email.Dkim do
  @moduledoc """
  DKIM-Signature verification (RFC 6376 subset) over a raw RFC 5322 message, using
  `:public_key` and `:crypto`. Usable as the `:signature_verifier` of
  `AshA2A.Email.Webhook` via `verifier/1`.

  Supported: `a=rsa-sha256`, `c=relaxed/relaxed` (must be explicit), body hash `bh=`,
  signed header list `h=` (bottom-most instances, RFC 6376 5.4.2), signature `b=`, key
  supplied by the caller (`:key_resolver`).

  Refused (`{:error, reason}`):

    * `:no_signature`, `:malformed_signature`, `:duplicate_tag`, `:unsupported_version`,
      `:unsupported_algorithm`, `:unsupported_canonicalization` (anything but relaxed/relaxed)
    * `:body_length_limit` -- any `l=` tag (a truncated body hash lets an attacker append content)
    * `:from_not_signed` -- `h=` does not cover `from`; `:multiple_from` -- more than one From
    * `:from_misaligned` -- From domain is neither `d=` nor a subdomain of it (disable with
      `require_from_alignment: false`)
    * `:expired` (`x=` in the past), `:future_timestamp` (`t=` more than 300s ahead)
    * `:key_unavailable`, `:key_revoked` (empty `p=`), `:bad_key`, `:weak_key` (< 1024-bit RSA)
    * `:body_hash_mismatch`, `:bad_signature`

  Options: `:key_resolver` (required) -- `(domain, selector -> {:ok, p} | {:error, _})` where `p`
  is the base64 `p=` value of the DNS TXT record (SubjectPublicKeyInfo or PKCS#1 DER) or an
  `{:RSAPublicKey, n, e}` tuple; `:now` -- zero-arity unix-seconds clock;
  `:require_from_alignment` (default `true`).

  This proves only that the signing domain vouched for the message. It confers no authority;
  the plug's sender allowlist, reply tokens and the kernel still decide.
  """

  @skew 300
  @min_bits 1024

  @doc "Verify `raw` (binary message). `:ok` when at least one DKIM-Signature verifies."
  @spec verify(binary(), keyword()) :: :ok | {:error, atom()}
  def verify(raw, opts) when is_binary(raw) do
    resolver =
      case Keyword.get(opts, :key_resolver) do
        fun when is_function(fun, 2) -> fun
        _ -> raise ArgumentError, "AshA2A.Email.Dkim requires a 2-arity :key_resolver"
      end

    {headers, body} = split(raw)

    case Enum.filter(headers, fn {name, _} -> String.downcase(name) == "dkim-signature" end) do
      [] ->
        {:error, :no_signature}

      sigs ->
        Enum.reduce_while(sigs, {:error, :no_signature}, fn sig, _acc ->
          case verify_one(sig, headers, body, resolver, opts) do
            :ok -> {:halt, :ok}
            {:error, _} = err -> {:cont, err}
          end
        end)
    end
  end

  def verify(_, _), do: {:error, :malformed_message}

  @doc """
  Returns an arity-1 function for `AshA2A.Email.Webhook`'s `:signature_verifier`. It accepts a raw
  message binary, a map with `"content"`/`"raw"` (atom keys too), or an SNS envelope whose
  `"Message"` is JSON carrying `"content"`; it returns `true` only when `verify/2` is `:ok`.
  """
  @spec verifier(keyword()) :: (term() -> boolean())
  def verifier(opts) do
    fn input ->
      case extract(input) do
        raw when is_binary(raw) -> verify(raw, opts) == :ok
        _ -> false
      end
    end
  end

  defp extract(raw) when is_binary(raw), do: raw

  defp extract(%{} = m) do
    Enum.find_value(["content", :content, "raw", :raw], fn k ->
      case Map.get(m, k) do
        v when is_binary(v) -> v
        _ -> nil
      end
    end) || extract_sns(m)
  end

  defp extract(_), do: nil

  defp extract_sns(%{"Message" => msg}) when is_binary(msg) do
    case Jason.decode(msg) do
      {:ok, %{"content" => c}} when is_binary(c) -> c
      _ -> nil
    end
  end

  defp extract_sns(_), do: nil

  # -- one signature -------------------------------------------------------------

  defp verify_one({_, sig_raw} = sig, headers, body, resolver, opts) do
    with {:ok, tags} <- parse_tags(sig_raw),
         :ok <- check_tags(tags),
         {:ok, h_names} <- signed_names(tags),
         {:ok, from_domain} <- from_domain(headers),
         :ok <- alignment(from_domain, tags["d"], opts),
         :ok <- check_times(tags, opts),
         :ok <- check_body_hash(body, tags["bh"]),
         {:ok, key} <- fetch_key(resolver, tags["d"], tags["s"]),
         {:ok, signature} <- decode_b64(tags["b"]) do
      data = signing_input(headers, h_names, sig, sig_raw)

      if rsa_verify(data, signature, key), do: :ok, else: {:error, :bad_signature}
    end
  end

  defp check_tags(tags) do
    cond do
      tags["v"] != "1" -> {:error, :unsupported_version}
      Map.has_key?(tags, "l") -> {:error, :body_length_limit}
      tags["a"] != "rsa-sha256" -> {:error, :unsupported_algorithm}
      tags["c"] != "relaxed/relaxed" -> {:error, :unsupported_canonicalization}
      Enum.any?(~w(d s h bh b), &(Map.get(tags, &1, "") == "")) -> {:error, :malformed_signature}
      true -> :ok
    end
  end

  defp signed_names(tags) do
    names =
      tags["h"] |> String.split(":") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    if "from" in names, do: {:ok, names}, else: {:error, :from_not_signed}
  end

  defp from_domain(headers) do
    case Enum.filter(headers, fn {n, _} -> String.downcase(n) == "from" end) do
      [{_, value}] ->
        case Regex.scan(~r/@([A-Za-z0-9.\-]+)/, value) do
          [] -> {:error, :from_misaligned}
          matches -> {:ok, matches |> List.last() |> List.last() |> String.downcase()}
        end

      [] ->
        {:error, :from_not_signed}

      _ ->
        {:error, :multiple_from}
    end
  end

  defp alignment(from_domain, d, opts) do
    d = String.downcase(d)

    cond do
      Keyword.get(opts, :require_from_alignment, true) == false -> :ok
      from_domain == d or String.ends_with?(from_domain, "." <> d) -> :ok
      true -> {:error, :from_misaligned}
    end
  end

  defp check_times(tags, opts) do
    now = now(opts)

    with {:ok, x} <- int_tag(tags, "x"),
         {:ok, t} <- int_tag(tags, "t") do
      cond do
        x != nil and now > x -> {:error, :expired}
        t != nil and t > now + @skew -> {:error, :future_timestamp}
        true -> :ok
      end
    end
  end

  defp int_tag(tags, name) do
    case Map.fetch(tags, name) do
      :error ->
        {:ok, nil}

      {:ok, v} ->
        case Integer.parse(v) do
          {i, ""} when i >= 0 -> {:ok, i}
          _ -> {:error, :malformed_signature}
        end
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.os_time(:second)
    end
  end

  defp check_body_hash(body, bh) do
    with {:ok, claimed} <- decode_b64(bh) do
      actual = :crypto.hash(:sha256, canon_body(body))

      if byte_size(claimed) == byte_size(actual) and :crypto.hash_equals(claimed, actual),
        do: :ok,
        else: {:error, :body_hash_mismatch}
    end
  end

  defp decode_b64(value) do
    case Base.decode64(String.replace(value, ~r/\s+/, ""), padding: true) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed_signature}
    end
  end

  # -- canonicalization (relaxed) ----------------------------------------------

  @doc false
  def canon_body(body) do
    lines =
      body
      |> String.split("\r\n")
      |> Enum.map(fn line ->
        line |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing(" ")
      end)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    case lines do
      [] -> ""
      _ -> Enum.join(lines, "\r\n") <> "\r\n"
    end
  end

  defp canon_header(name, value) do
    String.downcase(name) <> ":" <> canon_value(value)
  end

  defp canon_value(value) do
    value
    |> String.replace(~r/\r?\n/, "")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim(" ")
  end

  defp signing_input(headers, h_names, {sig_name, _}, sig_raw) do
    # Bottom-most unused instance of each named header, in h= order.
    pools =
      headers
      |> Enum.reverse()
      |> Enum.group_by(fn {n, _} -> String.downcase(n) end)

    {chosen, _} =
      Enum.reduce(h_names, {[], pools}, fn name, {acc, pools} ->
        case Map.get(pools, name, []) do
          [{n, v} | rest] -> {[canon_header(n, v) <> "\r\n" | acc], Map.put(pools, name, rest)}
          [] -> {acc, pools}
        end
      end)

    stripped = Regex.replace(~r/((?:^|;)\s*b\s*=)[^;]*/, sig_raw, "\\1")

    IO.iodata_to_binary([Enum.reverse(chosen), canon_header(sig_name, stripped)])
  end

  # -- parsing -------------------------------------------------------------------

  defp parse_tags(raw) do
    parts =
      raw
      |> String.replace(~r/\r?\n/, "")
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(parts, {:ok, %{}}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [k, v] ->
          k = String.trim(k)

          if Map.has_key?(acc, k),
            do: {:halt, {:error, :duplicate_tag}},
            else: {:cont, {:ok, Map.put(acc, k, String.trim(v))}}

        _ ->
          {:halt, {:error, :malformed_signature}}
      end
    end)
  end

  # Returns {[{name, raw_value}], body}; raw_value keeps folds, excludes the leading colon.
  defp split(raw) do
    raw = String.replace(raw, ~r/\r?\n/, "\r\n")

    {head, body} =
      case String.split(raw, "\r\n\r\n", parts: 2) do
        [h, b] -> {h, b}
        [h] -> {String.trim_trailing(h, "\r\n"), ""}
      end

    headers =
      head
      |> String.split("\r\n")
      |> Enum.reduce([], fn
        <<c, _::binary>> = line, [{n, v} | rest] when c in [?\s, ?\t] ->
          [{n, v <> "\r\n" <> line} | rest]

        line, acc ->
          case String.split(line, ":", parts: 2) do
            [n, v] -> [{n, v} | acc]
            _ -> acc
          end
      end)
      |> Enum.reverse()

    {headers, body}
  end

  # -- keys ----------------------------------------------------------------------

  defp fetch_key(resolver, domain, selector) do
    result =
      try do
        resolver.(domain, selector)
      rescue
        _ -> :error
      catch
        _, _ -> :error
      end

    case result do
      {:ok, {:RSAPublicKey, n, e} = key} when is_integer(n) and is_integer(e) -> check_size(key)
      {:ok, p} when is_binary(p) -> decode_key(p)
      _ -> {:error, :key_unavailable}
    end
  end

  defp decode_key(p) do
    case String.replace(p, ~r/\s+/, "") do
      "" ->
        {:error, :key_revoked}

      clean ->
        with {:ok, der} <- Base.decode64(clean),
             {:ok, key} <- der_to_rsa(der) do
          check_size(key)
        else
          _ -> {:error, :bad_key}
        end
    end
  end

  defp der_to_rsa(der) do
    {:ok, :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})}
  rescue
    _ ->
      try do
        {:ok, :public_key.der_decode(:RSAPublicKey, der)}
      rescue
        _ -> :error
      end
  end

  defp check_size({:RSAPublicKey, n, _e} = key) do
    if bit_length(n) >= @min_bits, do: {:ok, key}, else: {:error, :weak_key}
  end

  defp check_size(_), do: {:error, :bad_key}

  defp bit_length(n), do: n |> :binary.encode_unsigned() |> byte_size() |> Kernel.*(8)

  defp rsa_verify(data, signature, key) do
    :public_key.verify(data, :sha256, signature, key)
  rescue
    _ -> false
  end
end
