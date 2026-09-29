defmodule AshA2A.C2.AuthorityClient.Remote do
  @behaviour AshA2A.C2.AuthorityClient

  alias AshA2A.C2.{AuthorityResponse, Wire}

  @impl true
  def authorize(request, ctx) do
    with {:ok, endpoint} <- endpoint(ctx, :authority_endpoint),
         {:ok, body} <- Wire.authority_request(request),
         {:ok, response} <- Req.post(endpoint, json: body, receive_timeout: timeout(ctx)),
         {:ok, result} <- decode(response.status, response.body) do
      {:ok, result}
    end
  end

  defp decode(status, %{"decision" => "admit", "certificate" => cert}) when status in 200..299 do
    with {:ok, decoded} <- Wire.decode_certificate(cert), do: {:ok, AuthorityResponse.admit(decoded)}
  end

  defp decode(status, %{"decision" => "refuse", "reason" => reason}) when status in 200..499,
    do: {:ok, AuthorityResponse.refuse(reason)}

  defp decode(_, _), do: {:error, :authority_transport_refused}

  defp endpoint(ctx, key) do
    case Map.fetch(ctx, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_c2_endpoint, key}}
    end
  end

  defp timeout(ctx), do: Map.get(ctx, :c2_receive_timeout, 5_000)
end
