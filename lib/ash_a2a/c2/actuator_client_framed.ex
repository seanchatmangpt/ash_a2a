# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ActuatorClient.Framed do
  @moduledoc """
  Control-plane client for the separate `actuator` release (docs/reference/c2-wire-interop.md).

  Speaks the actuator's UDS wire: one 4-byte-length-prefixed JSON frame per request
  (`{"op":"execute","effect":<b64url canonical bytes>,"certificate":<b64url cert JSON>}`).
  The effect bytes are re-derived from the `PreparedEffect` (`AshA2A.C2.ActuatorProfile`) and
  the certificate must bind exactly their digest, else nothing is sent
  (`{:error, :effect_digest_mismatch}`). The control plane holds no key, so the actuator's
  verdict is the only admission.

  `ctx` keys: `:actuator_socket` (path, required), `:policy_epoch` (the epoch the effect
  is bound to), `:c2_receive_timeout` (ms, default 5000).

  Result mapping: `status` `"performed"`/`"replayed"` -> `{:ok, %{"state" => "executed", ...}}`;
  a refusal -> `{:error, {:actuator_refused, code}}`.
  """
  @behaviour AshA2A.C2.ActuatorClient

  alias AshA2A.C2.ActuatorProfile

  @impl true
  def execute(effect, cert, ctx) do
    with {:ok, path} <- socket(ctx),
         {:ok, eff} <- ActuatorProfile.effect(effect, Map.get(ctx, :policy_epoch, -1)),
         true <- cert.effect_digest == eff.digest or {:error, :effect_digest_mismatch},
         {:ok, cert_json} <- ActuatorProfile.certificate_json(cert),
         frame =
           Jason.encode!(%{
             "op" => "execute",
             "effect" => Base.url_encode64(eff.bytes, padding: false),
             "certificate" => Base.url_encode64(cert_json, padding: false)
           }),
         {:ok, reply} <- call(path, frame, Map.get(ctx, :c2_receive_timeout, 5_000)) do
      decode(reply, eff.digest)
    end
  end

  defp decode(%{"ok" => true, "status" => status, "evidence" => ev}, digest)
       when status in ["performed", "replayed"],
       do:
         {:ok,
          %{
            "state" => "executed",
            "status" => status,
            "effect_digest" => digest,
            "evidence" => ev
          }}

  defp decode(%{"ok" => false, "refusal" => code}, _) when is_binary(code),
    do: {:error, {:actuator_refused, code}}

  defp decode(_, _), do: {:error, :actuator_transport_refused}

  defp socket(ctx) do
    case Map.get(ctx, :actuator_socket) do
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, {:missing_c2_endpoint, :actuator_socket}}
    end
  end

  defp call(path, frame, timeout) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, packet: 4, active: false],
           timeout
         ) do
      {:ok, s} ->
        try do
          with :ok <- :gen_tcp.send(s, frame),
               {:ok, resp} <- :gen_tcp.recv(s, 0, timeout),
               {:ok, %{} = m} <- Jason.decode(resp) do
            {:ok, m}
          else
            _ -> {:error, :actuator_transport_refused}
          end
        after
          :gen_tcp.close(s)
        end

      {:error, _} ->
        {:error, :actuator_transport_refused}
    end
  end
end
