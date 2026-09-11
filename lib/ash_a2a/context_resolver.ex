defmodule AshA2A.ContextResolver do
  @moduledoc """
  Resolves a real `AshA2A.ExecutionContext` from an inbound `A2A.Message`.

  This is the trust boundary named in the ash_a2a PRD/ARD §3.5: raw A2A message
  metadata must never be passed straight into an Ash call (`Ash.Changeset.for_create/3`,
  `Ash.Query.for_read/3`, `Ash.ActionInput.for_action/3`, etc). Every dispatch path
  goes through `from_a2a_message/4` first, which extracts exactly the fields Ash
  actions accept (`actor`, `tenant`, `context`) plus the resolved `domain` and
  prior-turn `history`, and discards everything else in the message's
  `metadata` map.

  ## `actor`/`tenant` are never read from `message.metadata`

  `A2A.Message.metadata` (`~/xaas/deps/a2a/lib/a2a/message.ex:10-18`,
  `metadata: map()`) is parsed straight from the caller's JSON-RPC request body
  (`~/xaas/deps/a2a/lib/a2a/plug.ex:198`, `message = params["message"]`) — an
  arbitrary, unauthenticated, remote-caller-controlled object with no schema
  and nothing tying any of its keys to who is actually sending the message. A
  remote client can put anything it wants under `metadata["actor"]` (e.g.
  `%{"id" => "any-admin-id", "role" => "admin"}`) or `metadata["tenant"]` (e.g.
  a victim tenant id). Ash policy authorizers (`actor_attribute_equals`,
  `relates_to_actor_via`, multitenancy strategies, etc.) gate on exactly these
  two fields, so treating message metadata as their source is a full
  actor-impersonation / tenant-isolation bypass. This previously happened
  directly (`fetch(metadata, :actor)`, `fetch(metadata, :tenant)`),
  contradicting this moduledoc's own trust-boundary contract.

  The *verified* identity lives elsewhere entirely: `A2A.Plug.Auth` verifies
  real credentials and stores the result in `conn.private[:a2a][:auth]`
  (`~/xaas/deps/a2a/lib/a2a/plug/auth.ex:6-16,60-76`), which `A2A.Plug` then
  merges into the **call-level** `metadata` opt
  (`~/xaas/deps/a2a/lib/a2a/plug.ex:159`, `Map.put(metadata, "a2a.auth", auth)`
  on `opts.metadata` inside `resolve_opts/2`) — that opt flows into
  `GenServer.call(agent, {:message, message, opts})`
  (`~/xaas/deps/a2a/lib/a2a/plug.ex:275`) and from there into
  `A2A.Agent.Runtime.process_message/5`'s `metadata` argument
  (`~/xaas/deps/a2a/lib/a2a/agent.ex:272,286-291`), which becomes
  `Task.new(metadata: metadata)` and ultimately `context().metadata` — the
  **second argument** `handle_message/2` receives — **never the inbound
  `A2A.Message.t()`'s own `:metadata` field**, which `A2A.Plug` never touches
  at all. So a lookup keyed on `message.metadata["a2a.auth"]` could never
  observe the real verified identity (it structurally isn't there), and would
  only invite the same spoofing problem one key over.

  `from_a2a_message/4` therefore takes the verified identity as an explicit
  `auth_identity` argument rather than reading anything actor/tenant-shaped
  out of `a2a_message`. A correctly-wired dispatcher sources `auth_identity`
  from `A2A.Agent.context().metadata["a2a.auth"]` (specifically its `:identity`
  field, per `A2A.Plug.Auth.build_identity/2`,
  `~/xaas/deps/a2a/lib/a2a/plug/auth.ex:226-242`) — never from `a2a_message`
  itself. It defaults to `nil` (unauthenticated / no actor, no tenant claim)
  when the caller supplies nothing, so an unauthenticated or not-yet-wired
  dispatch path fails closed rather than silently trusting any value read from
  the message.

  Field provenance:

    * `:actor`   — **never** read from `message.metadata`. Set to the explicit
      `auth_identity` argument (default `nil`) verbatim — `auth_identity` IS
      the actor, since it is already the verified identity map produced
      out-of-band by the caller's `A2A.Plug.Auth` `:verify` callback.
    * `:tenant`  — **never** read from `message.metadata`. Extracted from
      `auth_identity[:tenant]` (or `auth_identity["tenant"]`) when
      `auth_identity` is a map; `nil` when `auth_identity` is `nil` or has no
      tenant claim. Never falls back to caller-supplied `metadata[:tenant]`.
    * `:context` — read from `message.metadata[:context]` (or `"context"`); defaults
      to `%{}` when absent, mirroring `AshAi.Tool.Execution.build_opts/2`'s
      `context[:context] || %{}` (`~/xaas/deps/ash_ai/lib/ash_ai/tool/execution.ex:100-107`).
      `:context` is not a privilege-bearing field (it never determines
      authorization or row visibility on its own) and is passed straight
      through to actions the way `AshAi.Tool.Execution` already does, so it is
      intentionally still sourced from raw metadata.
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
  Ash domain module that owns the skill being dispatched, an optional
  prior-turn `history` from the `A2A.Agent` task context (empty for a fresh
  task), and the transport-verified `auth_identity` for the caller (or `nil`
  when unauthenticated / not yet wired by the caller).

  `domain` and `history` are supplied by the caller (the skill dispatcher),
  never derived from message metadata — the message is untrusted input and
  must not be able to name its own domain or fabricate prior-turn history.

  `auth_identity` MUST be sourced from a real, out-of-band-verified identity —
  for an `A2A.Plug`-fronted agent, the `:identity` field of
  `A2A.Agent.context().metadata["a2a.auth"]` (populated exclusively by
  `A2A.Plug.Auth` after actual credential verification, see moduledoc) — and
  MUST NOT be read from `a2a_message.metadata`, which is unauthenticated wire
  input a remote caller fully controls end to end. Omitting this argument (or
  passing `nil`) resolves both `actor` and `tenant` to `nil`; neither ever
  falls back to an unverified value read from the message.

  ## Examples

      iex> message = A2A.Message.new_user("hi")
      iex> ctx = AshA2A.ContextResolver.from_a2a_message(message, AshA2A.Test.Fixture.Domain)
      iex> {ctx.actor, ctx.tenant, ctx.context, ctx.domain, ctx.history}
      {nil, nil, %{}, AshA2A.Test.Fixture.Domain, []}

      iex> message = A2A.Message.new_user("hi")
      iex> ctx = AshA2A.ContextResolver.from_a2a_message(
      ...>   message,
      ...>   AshA2A.Test.Fixture.Domain,
      ...>   [],
      ...>   %{id: "user-1", tenant: "acme"}
      ...> )
      iex> {ctx.actor, ctx.tenant}
      {%{id: "user-1", tenant: "acme"}, "acme"}

      iex> message = A2A.Message.new_user("hi")
      iex> reply = A2A.Message.new_user("prior turn")
      iex> ctx = AshA2A.ContextResolver.from_a2a_message(message, AshA2A.Test.Fixture.Domain, [reply])
      iex> ctx.history
      [reply]

  """
  @spec from_a2a_message(A2A.Message.t(), module(), [A2A.Message.t()], term()) ::
          ExecutionContext.t()
  def from_a2a_message(
        %A2A.Message{metadata: metadata},
        domain,
        history \\ [],
        auth_identity \\ nil
      )
      when is_atom(domain) and is_list(history) do
    metadata = metadata || %{}

    %ExecutionContext{
      actor: auth_identity,
      tenant: tenant_claim(auth_identity),
      context: fetch(metadata, :context) || %{},
      domain: domain,
      history: history
    }
  end

  defp tenant_claim(auth_identity) when is_map(auth_identity), do: fetch(auth_identity, :tenant)
  defp tenant_claim(_auth_identity), do: nil

  defp fetch(metadata, key) when is_map(metadata) do
    AshA2A.MetadataKey.get(metadata, key)
  end
end
