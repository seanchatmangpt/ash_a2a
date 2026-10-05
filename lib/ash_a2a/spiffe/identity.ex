# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.Identity do
  @moduledoc """
  Parsed SPIFFE workload identity (`spiffe://trust-domain/path`), validated by `parse/1`.
  An identity claim is evidence only; it never substitutes for a C2 certificate.
  """

  @enforce_keys [:uri, :trust_domain, :path]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          uri: String.t(),
          trust_domain: String.t(),
          path: String.t()
        }

  def parse(raw) when is_binary(raw) do
    uri = URI.parse(raw)

    cond do
      uri.scheme != "spiffe" ->
        {:error, :invalid_spiffe_scheme}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, :missing_trust_domain}

      not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, :spiffe_query_fragment_forbidden}

      not is_nil(uri.userinfo) or not is_nil(uri.port) ->
        {:error, :spiffe_authority_invalid}

      true ->
        path = uri.path || ""
        {:ok, %__MODULE__{uri: "spiffe://#{uri.host}#{path}", trust_domain: uri.host, path: path}}
    end
  end

  def parse(_), do: {:error, :invalid_spiffe_id}
end
