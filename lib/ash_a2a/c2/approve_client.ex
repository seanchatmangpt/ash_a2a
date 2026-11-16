# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.ApproveClient do
  @moduledoc """
  Submits one signed approval to the `authority_service` `"approve"` wire op.

  Tested by `test/ash_a2a/c2/approve_client_test.exs` against a stand-in listener that speaks
  the same framing, not against the real `authority_service` release.

  Same framing and transport as `AshA2A.C2.AuthorityClient.Framed`: one `<<len::32, json>>`
  frame per connection over a unix socket (`ctx.authority_socket`) or mutual TLS
  (`ctx.c2_tls`, see `AshA2A.C2.L07Tls.Transport`; with `:c2_tls` set the socket is never used).

  The service only deposits the approval in its mailbox; the issuer re-verifies signature,
  registry standing, digest, principal, generation, epoch, TTL, replay and custodian
  distinctness when `issue` runs. A successful submit therefore grants nothing by itself.

  `approval` is the wire form `%{"envelope" => map, "message" => base64url}` that
  `sa2a-approver approve` builds, or any equivalent producer.

  Returns `:ok`, `{:error, {:refused, code}}` (the service refused, for example
  `"duplicate_approval"`, `"malformed_approval"`, `"unknown_op"`) or
  `{:error, :authority_transport_refused}` / `{:error, {:missing_c2_endpoint, :authority_socket}}`.
  """

  alias AshA2A.C2.L07Tls.Transport

  @max_reply 1_048_576

  @spec submit(map(), String.t(), String.t(), non_neg_integer(), map()) ::
          :ok | {:error, term()}
  def submit(ctx, approver, effect_digest, generation, approval)
      when is_map(ctx) and is_binary(approver) and approver != "" and is_binary(effect_digest) and
             is_integer(generation) and generation >= 0 and is_map(approval) do
    body =
      Jason.encode!(%{
        "op" => "approve",
        "approver" => approver,
        "effect_digest" => effect_digest,
        "generation" => generation,
        "approval" => approval
      })

    with {:ok, path} <- socket(ctx),
         {:ok, reply} <- call(path, ctx, body, Map.get(ctx, :c2_receive_timeout, 5_000)) do
      decode(reply)
    end
  end

  def submit(_, _, _, _, _), do: {:error, :malformed_request}

  defp decode(%{"ok" => true}), do: :ok
  defp decode(%{"ok" => false, "refusal" => code}) when is_binary(code), do: {:error, {:refused, code}}
  defp decode(_), do: {:error, :authority_transport_refused}

  defp socket(%{c2_tls: _}), do: {:ok, nil}

  defp socket(ctx) do
    case Map.get(ctx, :authority_socket) do
      p when is_binary(p) and p != "" -> {:ok, p}
      _ -> {:error, {:missing_c2_endpoint, :authority_socket}}
    end
  end

  defp call(path, ctx, body, timeout) do
    case Transport.connect(path, ctx, [:binary, packet: :raw, active: false], timeout) do
      {:ok, s} ->
        try do
          with :ok <- Transport.send(s, <<byte_size(body)::32, body::binary>>),
               {:ok, <<len::32>>} <- Transport.recv(s, 4, timeout),
               true <- len <= @max_reply,
               {:ok, resp} <- Transport.recv(s, len, timeout),
               {:ok, %{} = m} <- Jason.decode(resp) do
            {:ok, m}
          else
            _ -> {:error, :authority_transport_refused}
          end
        after
          Transport.close(s)
        end

      {:error, _} ->
        {:error, :authority_transport_refused}
    end
  end
end
