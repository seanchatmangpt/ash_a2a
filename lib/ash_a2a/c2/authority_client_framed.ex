defmodule AshA2A.C2.AuthorityClient.Framed do
  @moduledoc """
  Control-plane client for the separate `authority_service` release (docs/reference/c2-wire-interop.md).

  Speaks the service's typed wire: one `<<len::32, json>>` frame per connection over a unix
  socket (`ctx.authority_socket`). Only the `"issue"` op exists. The effect is sent as the
  exact actuator-profile canonical bytes (`AshA2A.C2.ActuatorProfile.effect/2`); the service
  recomputes the digest from those bytes and decides the class from them.

  `ctx` keys: `:authority_socket` (path, required), `:approvals` (wire approvals, default `[]`),
  `:c2_receive_timeout` (ms, default 5000). The certificate that comes back binds the ACTUATOR
  digest, which the framed actuator client re-derives before sending.
  """
  @behaviour AshA2A.C2.AuthorityClient

  alias AshA2A.C2.{ActuatorProfile, AuthorityResponse}

  @max_reply 1_048_576

  @impl true
  def authorize(request, ctx) do
    with {:ok, path} <- socket(ctx),
         {:ok, eff} <- ActuatorProfile.effect(request.effect, request.policy_epoch),
         body =
           Jason.encode!(%{
             "op" => "issue",
             "effect" => Base.url_encode64(eff.bytes, padding: false),
             "effect_digest" => eff.digest,
             "audience" => request.audience,
             "generation" => request.generation,
             "approvals" => Map.get(ctx, :approvals, [])
           }),
         {:ok, reply} <- call(path, body, Map.get(ctx, :c2_receive_timeout, 5_000)) do
      decode(reply, eff.digest)
    end
  end

  defp decode(%{"ok" => true, "certificate" => cert}, digest) do
    with {:ok, c} <- ActuatorProfile.certificate_from_authority(cert),
         true <- c.effect_digest == digest or {:error, :effect_digest_mismatch} do
      {:ok, AuthorityResponse.admit(c)}
    end
  end

  defp decode(%{"ok" => false, "refusal" => code}, _digest) when is_binary(code),
    do: {:ok, AuthorityResponse.refuse(code)}

  defp decode(_, _), do: {:error, :authority_transport_refused}

  defp socket(ctx) do
    case Map.get(ctx, :authority_socket) do
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, {:missing_c2_endpoint, :authority_socket}}
    end
  end

  defp call(path, body, timeout) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, packet: :raw, active: false],
           timeout
         ) do
      {:ok, s} ->
        try do
          with :ok <- :gen_tcp.send(s, <<byte_size(body)::32, body::binary>>),
               {:ok, <<len::32>>} <- :gen_tcp.recv(s, 4, timeout),
               true <- len <= @max_reply,
               {:ok, resp} <- :gen_tcp.recv(s, len, timeout),
               {:ok, %{} = m} <- Jason.decode(resp) do
            {:ok, m}
          else
            _ -> {:error, :authority_transport_refused}
          end
        after
          :gen_tcp.close(s)
        end

      {:error, _} ->
        {:error, :authority_transport_refused}
    end
  end
end
