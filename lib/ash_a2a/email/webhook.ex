defmodule AshA2A.Email.Webhook do
  @moduledoc """
  Fail-closed authentication of inbound-email provider webhooks.

  Every function returns `:ok | {:error, reason}`; anything missing, malformed or
  unconfigured is an error. All secret comparisons are constant time.

    * `verify(:sendgrid, conn_or_headers, opts)` -- `opts[:secret]` matched against
      the `x-webhook-secret` header or the HTTP Basic password.
    * `verify(:workspace, ..., opts)` -- `opts[:token]` against the Bearer token.
    * `verify(:ses, body, opts)` -- structural check of an SNS envelope: required
      fields, `SigningCertURL` host must be `sns.<region>.amazonaws.com` over https,
      `SignatureVersion` 1|2, base64 `Signature`, and optionally `:topic_arn`.
      This does NOT verify the RSA signature; supply `opts[:signature_verifier]`
      (arity-1 fun over the decoded body) for cryptographic verification. Without
      it the result is `{:error, :signature_unverified}` unless `structure_only: true`.
  """

  @type headers :: [{String.t(), String.t()}] | %{optional(String.t()) => String.t()}

  @spec verify(:sendgrid | :workspace | :ses, term(), keyword()) :: :ok | {:error, atom()}
  def verify(provider, input, opts \\ [])

  def verify(:sendgrid, input, opts) do
    with {:ok, secret} <- configured(opts[:secret]) do
      candidates =
        [header(input, "x-webhook-secret"), basic_password(header(input, "authorization"))]
        |> Enum.filter(&is_binary/1)

      # evaluate all candidates (no short-circuit on first match leak of position)
      if Enum.reduce(candidates, false, fn c, acc -> secure_equal?(c, secret) or acc end),
        do: :ok,
        else: {:error, :unauthorized}
    end
  end

  def verify(:workspace, input, opts) do
    with {:ok, token} <- configured(opts[:token]) do
      case header(input, "authorization") do
        "Bearer " <> given -> if secure_equal?(given, token), do: :ok, else: {:error, :unauthorized}
        _ -> {:error, :unauthorized}
      end
    end
  end

  def verify(:ses, body, opts) do
    with {:ok, msg} <- decode(body),
         :ok <- ses_structure(msg),
         :ok <- ses_topic(msg, opts[:topic_arn]) do
      case opts[:signature_verifier] do
        fun when is_function(fun, 1) -> if fun.(msg) == true, do: :ok, else: {:error, :bad_signature}
        _ -> if opts[:structure_only] == true, do: :ok, else: {:error, :signature_unverified}
      end
    end
  end

  def verify(_, _, _), do: {:error, :unknown_provider}

  @doc "Constant-time binary equality; false for non-binaries or length mismatch."
  @spec secure_equal?(term(), term()) :: boolean()
  def secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      import Bitwise

      a
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(b))
      |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end)
      |> Kernel.==(0)
    else
      false
    end
  end

  def secure_equal?(_, _), do: false

  defp configured(v) when is_binary(v) and byte_size(v) >= 16, do: {:ok, v}
  defp configured(_), do: {:error, :not_configured}

  defp header(%{req_headers: hs}, name), do: header(hs, name)
  defp header(hs, name) when is_map(hs), do: header(Map.to_list(hs), name)

  defp header(hs, name) when is_list(hs) do
    Enum.find_value(hs, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  defp header(_, _), do: nil

  defp basic_password("Basic " <> b64) do
    with {:ok, dec} <- Base.decode64(String.trim(b64)),
         [_user, pass] <- String.split(dec, ":", parts: 2) do
      pass
    else
      _ -> nil
    end
  end

  defp basic_password(_), do: nil

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = m} -> {:ok, m}
      _ -> {:error, :malformed}
    end
  end

  defp decode(_), do: {:error, :malformed}

  @required ~w(Type MessageId TopicArn Timestamp Signature SignatureVersion SigningCertURL)

  defp ses_structure(msg) do
    cond do
      not Enum.all?(@required, &(is_binary(msg[&1]) and msg[&1] != "")) -> {:error, :malformed}
      msg["SignatureVersion"] not in ["1", "2"] -> {:error, :bad_signature_version}
      not match?({:ok, _}, Base.decode64(msg["Signature"])) -> {:error, :bad_signature_encoding}
      not sns_cert_url?(msg["SigningCertURL"]) -> {:error, :bad_cert_url}
      true -> :ok
    end
  end

  defp sns_cert_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path} when is_binary(host) and is_binary(path) ->
        Regex.match?(~r/\Asns\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\z/, host) and
          String.ends_with?(path, ".pem")

      _ ->
        false
    end
  end

  defp ses_topic(_msg, nil), do: :ok
  defp ses_topic(msg, arn), do: if(secure_equal?(msg["TopicArn"], arn), do: :ok, else: {:error, :topic_mismatch})
end
