# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ActuatorClient.Remote do
  @behaviour AshA2A.C2.ActuatorClient

  alias AshA2A.C2.Wire

  @impl true
  def execute(effect, cert, ctx) do
    with {:ok, endpoint} <- endpoint(ctx),
         {:ok, portable_effect} <- Wire.effect(effect),
         {:ok, response} <-
           Req.post(endpoint,
             json: %{
               "effect" => portable_effect,
               "effect_digest" => effect.digest,
               "certificate" => Wire.certificate(cert)
             },
             receive_timeout: Map.get(ctx, :c2_receive_timeout, 5_000)
           ),
         {:ok, result} <- decode(response.status, response.body) do
      {:ok, result}
    end
  end

  defp decode(status, %{"state" => "executed"} = receipt) when status in 200..299,
    do: {:ok, receipt}

  defp decode(status, %{"state" => "unknown_outcome"} = receipt) when status in 200..599,
    do: {:error, {:unknown_outcome, receipt}}

  defp decode(_, %{"refusal" => reason}), do: {:error, {:actuator_refused, reason}}
  defp decode(_, _), do: {:error, :actuator_transport_refused}

  defp endpoint(ctx) do
    case Map.fetch(ctx, :actuator_endpoint) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_c2_endpoint, :actuator_endpoint}}
    end
  end
end
