# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.AuthZEN.Metadata do
  @moduledoc """
  OpenID AuthZEN discovery metadata for a policy decision point, decoded by `decode/1`
  with HTTPS enforced and pinned to an expected PDP by `bind_expected/2`. Evidence only.
  """

  @known ~w(policy_decision_point access_evaluation_endpoint access_evaluations_endpoint search_subject_endpoint search_resource_endpoint search_action_endpoint capabilities signed_metadata)
  @enforce_keys [:policy_decision_point, :access_evaluation_endpoint]
  defstruct @enforce_keys ++
              [
                :access_evaluations_endpoint,
                :search_subject_endpoint,
                :search_resource_endpoint,
                :search_action_endpoint,
                capabilities: [],
                signed_metadata: nil,
                extensions: %{}
              ]

  def decode(raw) when is_map(raw) do
    map = Map.new(raw, fn {k, v} -> {to_string(k), v} end)
    pdp = map["policy_decision_point"]
    endpoint = map["access_evaluation_endpoint"] || default_endpoint(pdp)

    with :ok <- validate_pdp(pdp),
         :ok <- validate_https(endpoint),
         :ok <- validate_optional(map) do
      {:ok,
       %__MODULE__{
         policy_decision_point: pdp,
         access_evaluation_endpoint: endpoint,
         access_evaluations_endpoint: map["access_evaluations_endpoint"],
         search_subject_endpoint: map["search_subject_endpoint"],
         search_resource_endpoint: map["search_resource_endpoint"],
         search_action_endpoint: map["search_action_endpoint"],
         capabilities: List.wrap(map["capabilities"]),
         signed_metadata: map["signed_metadata"],
         extensions: Map.drop(map, @known)
       }}
    end
  end

  def decode(_), do: {:error, :invalid_metadata}

  def bind_expected(%__MODULE__{policy_decision_point: pdp}, pdp), do: :ok
  def bind_expected(%__MODULE__{}, _), do: {:error, :pdp_mixup}

  defp default_endpoint(pdp) when is_binary(pdp),
    do: String.trim_trailing(pdp, "/") <> "/access/v1/evaluation"

  defp default_endpoint(_), do: nil

  defp validate_pdp(url) do
    with :ok <- validate_https(url),
         %URI{query: nil, fragment: nil} <- URI.parse(url) do
      :ok
    else
      _ -> {:error, :invalid_policy_decision_point}
    end
  end

  defp validate_optional(map) do
    ~w(access_evaluations_endpoint search_subject_endpoint search_resource_endpoint search_action_endpoint)
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case map[key] do
        nil ->
          {:cont, :ok}

        url ->
          case validate_https(url) do
            :ok -> {:cont, :ok}
            _ -> {:halt, {:error, :invalid_endpoint}}
          end
      end
    end)
  end

  defp validate_https(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and byte_size(host) > 0 -> :ok
      _ -> {:error, :https_required}
    end
  end

  defp validate_https(_), do: {:error, :https_required}
end
