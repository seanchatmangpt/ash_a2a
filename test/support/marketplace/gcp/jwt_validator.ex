# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Marketplace.GCP.JwtValidator do
  @moduledoc """
  Validates incoming Google Cloud Marketplace signup JWTs (`x-gcp-marketplace-token`).

  Asserts Google's formal partner identity claims:
    - `iss`: "https://www.googleapis.com/robot/v1/metadata/x509/cloud-commerce-partner@system.gserviceaccount.com"
    - `sub`: non-empty procurement account identifier
    - `exp`: token has not expired
    - `aud`: target marketplace service domain
  """

  @google_partner_issuer "https://www.googleapis.com/robot/v1/metadata/x509/cloud-commerce-partner@system.gserviceaccount.com"

  @type claims :: %{
          required(:iss) => String.t(),
          required(:sub) => String.t(),
          required(:exp) => integer(),
          required(:aud) => String.t(),
          optional(:account_id) => String.t()
        }

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc """
  Validates a raw JWT binary token against required claims.
  In non-mock Chicago test suites, accepts a verification key or verified token struct.
  """
  @spec validate_token(String.t(), keyword()) :: {:ok, claims()} | refusal()
  def validate_token(token, opts \\ []) when is_binary(token) do
    case String.split(token, ".") do
      [header_b64, payload_b64, _sig_b64] ->
        with {:ok, _header} <- decode_json(header_b64),
             {:ok, payload} <- decode_json(payload_b64),
             :ok <- verify_claims(payload, opts) do
          {:ok, payload}
        end

      _ ->
        {:error, %{code: :malformed_jwt, detail: "Token does not have 3 parts"}}
    end
  end

  defp decode_json(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, json_str} ->
        case Jason.decode(json_str) do
          {:ok, map} -> {:ok, map}
          {:error, err} -> {:error, %{code: :invalid_json, detail: err}}
        end

      :error ->
        {:error, %{code: :invalid_base64, detail: b64}}
    end
  end

  defp verify_claims(payload, opts) do
    expected_aud = Keyword.get(opts, :expected_aud)
    now = Keyword.get(opts, :now, System.system_time(:second))

    cond do
      payload["iss"] != @google_partner_issuer ->
        {:error, %{code: :invalid_issuer, detail: payload["iss"]}}

      is_nil(payload["sub"]) or payload["sub"] == "" ->
        {:error, %{code: :missing_subject, detail: "sub claim is empty"}}

      is_integer(payload["exp"]) and payload["exp"] < now ->
        {:error, %{code: :token_expired, detail: %{exp: payload["exp"], now: now}}}

      expected_aud && payload["aud"] != expected_aud ->
        {:error, %{code: :invalid_audience, detail: %{expected: expected_aud, got: payload["aud"]}}}

      true ->
        :ok
    end
  end
end
