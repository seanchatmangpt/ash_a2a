# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.PolicyEvidence.PdpClient do
  @moduledoc """
  Req-based AuthZEN PDP client (the PEP side). It yields `PolicyEvidence` only;
  it never calls the authority or an actuator. Redirects are disabled so a
  response cannot come from a PDP other than the configured identifier.

  `req_options` is merged into every request (e.g. `plug: {Req.Test, Stub}`).
  """

  alias AshA2A.C2.{AuthorityRequest, PolicyEvidence}

  @metadata_path "/.well-known/authzen-configuration"

  @spec evidence(AuthorityRequest.t(), binary(), keyword()) ::
          {:ok, PolicyEvidence.t()} | {:error, atom()}
  def evidence(%AuthorityRequest{} = r, pdp, req_options \\ []) when is_binary(pdp) do
    with :ok <- https(pdp),
         {:ok, metadata} <-
           request(:get, String.trim_trailing(pdp, "/") <> @metadata_path, nil, req_options),
         :ok <- PolicyEvidence.validate_metadata(metadata, pdp),
         {:ok, sarc} <- PolicyEvidence.sarc_request(r),
         {:ok, endpoint} <- endpoint(metadata),
         {:ok, response} <- request(:post, endpoint, sarc, req_options) do
      PolicyEvidence.from_response(r, response, pdp, metadata)
    end
  end

  defp endpoint(%{"access_evaluation_endpoint" => e}) when is_binary(e), do: {:ok, e}
  defp endpoint(_), do: {:error, :pdp_endpoint_missing}

  defp request(method, url, body, opts) do
    base = [method: method, url: url, redirect: false, retry: false]
    base = if body, do: Keyword.put(base, :json, body), else: base

    case Req.request(Keyword.merge(base, opts)) do
      {:ok, %Req.Response{status: 200, body: b}} when is_map(b) -> {:ok, b}
      {:ok, _} -> {:error, :pdp_bad_response}
      {:error, _} -> {:error, :pdp_unreachable}
    end
  end

  defp https("https://" <> _), do: :ok
  defp https(_), do: {:error, :pdp_not_https}
end
