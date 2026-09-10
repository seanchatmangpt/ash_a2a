defmodule AshA2A.ContextResolver do
  @moduledoc """
  Resolves a real `AshA2A.ExecutionContext` from an inbound `A2A.Message`.

  This is the trust boundary named in the ash_a2a PRD/ARD §3.5: raw A2A message
  metadata must never be passed straight into an Ash call (`Ash.Changeset.for_create/3`,
  `Ash.Query.for_read/3`, `Ash.ActionInput.for_action/3`, etc). Every dispatch path
  goes through `from_a2a_message/2` first, which extracts exactly the fields Ash
  actions accept (`actor`, `tenant`, `context`) plus the resolved `domain`, and
  discards everything else in the message's `metadata` map.

  ## Authentication boundary

  `message.metadata` is caller-controlled, unauthenticated input end-to-end — any
  A2A network caller can set arbitrary keys in it. `actor` and `tenant` therefore
  must never be read directly off `message.metadata`; doing so lets a caller
  self-declare `metadata["actor"] = %{role: :admin}` and `metadata["tenant"] =
  <victim>` with zero validation (privilege escalation / tenant-isolation bypass).

  Instead `actor`/`tenant` are read exclusively from the *verified* identity that
  `A2A.Plug.Auth` produced from real credentials and that `A2A.Plug` forwards to
  the agent as `metadata["a2a.auth"]`
  (`~/xaas/deps/a2a/lib/a2a/plug/auth.ex:6-9`, `~/xaas/deps/a2a/lib/a2a/plug.ex:159`).
  That value has the shape built by `A2A.Plug.Auth.build_identity/2`
  (`~/xaas/deps/a2a/lib/a2a/plug/auth.ex:226-242`):

      %{scheme: scheme_name, identity: identity_map}
      # or, for a multi-scheme security requirement:
      %{scheme: first_scheme_name, identity: identity_map, identities: %{scheme_name => identity_map}}

  where `identity_map` is whatever the caller-supplied `:verify` callback returned
  in its `{:ok, identity_map}` result — application-defined, but conventionally
  carrying `:actor`/`"actor"` and `:tenant`/`"tenant"` keys the same way the rest
  of this module already expects.

  Field provenance:

    * `:actor`   — read from `metadata["a2a.auth"].identity[:actor]` (or `"actor"`).
      Absent (no verified identity, i.e. an exempt/unauthenticated path) → `nil`,
      never falls back to caller-supplied `metadata[:actor]`.
    * `:tenant`  — read from `metadata["a2a.auth"].identity[:tenant]` (or `"tenant"`).
      Same absent-means-`nil` rule as `:actor`.
    * `:context` — read from `message.metadata[:context]` (or `"context"`); defaults
      to `%{}` when absent, mirroring `AshAi.Tool.Execution.build_opts/2`'s
      `context[:context] || %{}` (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`).
      `:context` is not a privilege-bearing field (it never determines authorization
      or row visibility on its own) and is passed straight through to actions the
      way `AshAi.Tool.Execution` already does, so it is intentionally still sourced
      from raw metadata.
    * `:domain`  — never read from message metadata (a caller-supplied domain module
      is not something an inbound A2A message may set); it is always the second
      argument passed by the dispatcher that already knows which Ash domain owns
      the skill being invoked.
    * `:history` — never read from message metadata either; it is the
      `A2A.Agent.context().history` transcript the `A2A.Agent.Runtime` builds and
      passes to `handle_message/2` on a continued (multi-turn) task
      (`~/xaas/deps/a2a/lib/a2a/agent.ex:130-135`). Supplied explicitly by the
      dispatcher as a third argument, defaulting to `[]` for a fresh task.
  """

  alias AshA2A.ExecutionContext

  @doc """
  Builds an `AshA2A.ExecutionContext` from a real `A2A.Message` struct, the
  Ash domain module that owns the skill being dispatched, and the prior-turn
  `history` from the `A2A.Agent` task context (empty for a fresh task).

  `domain` and `history` are supplied by the caller (the skill dispatcher),
  never derived from message metadata — the message is untrusted input and
  must not be able to name its own domain or fabricate prior-turn history.

  `actor`/`tenant` are sourced exclusively from the verified identity `A2A.Plug`
  stores at `metadata["a2a.auth"]` (see moduledoc) — never from raw, caller-supplied
  `metadata[:actor]`/`metadata[:tenant]`.
  """
  @spec from_a2a_message(A2A.Message.t(), module(), [A2A.Message.t()]) :: ExecutionContext.t()
  def from_a2a_message(%A2A.Message{metadata: metadata}, domain, history \\ [])
      when is_atom(domain) and is_list(history) do
    metadata = metadata || %{}
    identity = verified_identity(metadata)

    %ExecutionContext{
      actor: fetch(identity, :actor),
      tenant: fetch(identity, :tenant),
      context: fetch(metadata, :context) || %{},
      domain: domain,
      history: history
    }
  end

  # `A2A.Plug` stores the verified auth result under the literal string key
  # "a2a.auth" (`~/xaas/deps/a2a/lib/a2a/plug.ex:159`) -- not `:"a2a.auth"` and
  # not `"a2a.auth"`'s atom form -- so this is looked up directly rather than
  # through `fetch/2`'s atom/string dance.
  defp verified_identity(metadata) when is_map(metadata) do
    case Map.get(metadata, "a2a.auth") do
      %{identity: identity} when is_map(identity) -> identity
      _ -> %{}
    end
  end

  defp fetch(metadata, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end
end
