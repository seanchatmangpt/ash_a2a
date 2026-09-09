defmodule AshA2A.ContextResolver do
  @moduledoc """
  Resolves a real `AshA2A.ExecutionContext` from an inbound `A2A.Message`.

  This is the trust boundary named in the ash_a2a PRD/ARD §3.5: raw A2A message
  metadata must never be passed straight into an Ash call (`Ash.Changeset.for_create/3`,
  `Ash.Query.for_read/3`, `Ash.ActionInput.for_action/3`, etc). Every dispatch path
  goes through `from_a2a_message/2` first, which extracts exactly the fields Ash
  actions accept (`actor`, `tenant`, `context`) plus the resolved `domain`, and
  discards everything else in the message's `metadata` map.

  Field provenance, matching `A2A.Message.t()`
  (`~/xaas/deps/a2a/lib/a2a/message.ex:10-18`, `metadata: map()`):

    * `:actor`   — read from `message.metadata[:actor]` (or the `"actor"` string key).
    * `:tenant`  — read from `message.metadata[:tenant]` (or `"tenant"`).
    * `:context` — read from `message.metadata[:context]` (or `"context"`); defaults
      to `%{}` when absent, mirroring `AshAi.Tool.Execution.build_opts/2`'s
      `context[:context] || %{}` (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`).
    * `:domain`  — never read from message metadata (a caller-supplied domain module
      is not something an inbound A2A message may set); it is always the second
      argument passed by the dispatcher that already knows which Ash domain owns
      the skill being invoked.
  """

  alias AshA2A.ExecutionContext

  @doc """
  Builds an `AshA2A.ExecutionContext` from a real `A2A.Message` struct and the
  Ash domain module that owns the skill being dispatched.

  `domain` is supplied by the caller (the skill dispatcher), never derived from
  message metadata — the message is untrusted input and must not be able to name
  its own domain.
  """
  @spec from_a2a_message(A2A.Message.t(), module()) :: ExecutionContext.t()
  def from_a2a_message(%A2A.Message{metadata: metadata}, domain) when is_atom(domain) do
    metadata = metadata || %{}

    %ExecutionContext{
      actor: fetch(metadata, :actor),
      tenant: fetch(metadata, :tenant),
      context: fetch(metadata, :context) || %{},
      domain: domain
    }
  end

  defp fetch(metadata, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end
end
