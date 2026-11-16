defmodule AuthorityService.ApproverChannel.Mailbox do
  @moduledoc """
  Approver channel fed by the control plane's `"approve"` wire op (UNVERIFIED: not run).

  An approver (for example `sa2a-approver`) signs the effect digest offline and submits the
  signed approval here with `submit/5`; `solicit/3` then hands it to the Issuer, which
  re-verifies it exactly like an attached approval (signature, registry standing, digest,
  principal, generation, epoch, TTL, replay journal, distinct custodians). The mailbox never
  grants standing; it only holds data. State is process-local and lost on restart, which is
  safe: an approval that is not delivered simply does not count.

  Refusals at submit time: `:malformed_approval`, `:duplicate_approval` (the same
  `(kid, nonce)` already held, or the `(digest, generation, approver)` slot already filled),
  `:mailbox_full`. Slots are first-wins, so a slot cannot be overwritten by a later submit.
  """
  @behaviour AuthorityService.ApproverChannel
  alias Sa2aCrypto.Envelope

  @max_entries 1024
  @max_message_bytes 8192

  @doc false
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{slots: %{}, seen: MapSet.new()} end, Keyword.take(opts, [:name]))
  end

  @doc """
  Hold `approval` (`%{"envelope" => map, "message" => b64url}`) for `approver_id` against
  `(effect_digest, generation)`.
  """
  @spec submit(GenServer.server(), String.t(), String.t(), non_neg_integer(), map()) ::
          :ok | {:error, atom()}
  def submit(server, approver_id, effect_digest, generation, approval)
      when is_binary(approver_id) and is_binary(effect_digest) and is_integer(generation) and
             generation >= 0 do
    with {:ok, %{envelope: env, message: bytes}} <- parse(approval) do
      key = {effect_digest, generation, approver_id}
      nonce_key = {env.kid, env.nonce}

      Agent.get_and_update(server, fn st ->
        cond do
          Map.has_key?(st.slots, key) or MapSet.member?(st.seen, nonce_key) ->
            {{:error, :duplicate_approval}, st}

          map_size(st.slots) >= @max_entries ->
            {{:error, :mailbox_full}, st}

          true ->
            {:ok,
             %{
               st
               | slots: Map.put(st.slots, key, %{envelope: env, message: bytes}),
                 seen: MapSet.put(st.seen, nonce_key)
             }}
        end
      end)
    end
  end

  def submit(_, _, _, _, _), do: {:error, :malformed_approval}

  @impl true
  def solicit(server, approver_id, %{effect_digest: d, generation: g}) do
    case Agent.get(server, &Map.fetch(&1.slots, {d, g, approver_id})) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, :no_response}
    end
  end

  defp parse(%{"envelope" => env, "message" => msg}) when is_map(env) and is_binary(msg) do
    with {:ok, bytes} <- Envelope.b64(msg),
         true <- byte_size(bytes) <= @max_message_bytes,
         {:ok, e} <- Envelope.decode(Jcs.encode(env)),
         true <- is_binary(e.kid) and is_binary(e.nonce) do
      {:ok, %{envelope: e, message: bytes}}
    else
      _ -> {:error, :malformed_approval}
    end
  rescue
    _ -> {:error, :malformed_approval}
  end

  defp parse(_), do: {:error, :malformed_approval}
end
