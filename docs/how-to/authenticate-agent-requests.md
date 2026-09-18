# How to authenticate inbound A2A requests and thread identity into your Ash actions

This guide wires a real `A2A.Plug.Auth` in front of a real `A2A.Plug`, so a Bearer
credential on an inbound A2A request becomes `context.actor`/`context.tenant` inside
your Ash action. It is based directly on the working end-to-end test
`test/ash_a2a_plug_auth_test.exs` and the trust-boundary code in
`lib/ash_a2a/context_resolver.ex` — every snippet below matches that real code.

## The trust boundary you need to understand first

`AshA2A.ContextResolver.from_a2a_message/4` never reads `actor`/`tenant` out of the
inbound `A2A.Message`'s own `metadata` field. That field is unauthenticated JSON-RPC
request body content — any caller can put `%{"actor" => %{"id" => "admin"}}` in it.
The only path an actor/tenant can take into your action is:

1. `A2A.Plug.Auth` verifies a real credential and stores the result in
   `conn.private[:a2a][:auth]`.
2. `A2A.Plug` merges that into the call's `metadata["a2a.auth"]`.
3. `AshA2A.Agent.__dispatch__` reads `metadata["a2a.auth"][:identity]` and passes it
   to `AshA2A.Dispatcher.dispatch/5` as `auth_identity`.
4. `AshA2A.ContextResolver.from_a2a_message/4` sets `context.actor` to that
   `auth_identity` verbatim, and `context.tenant` to `auth_identity[:tenant]` (or the
   string-keyed `"tenant"`), or `nil` if the caller never wired auth at all.

If you skip `A2A.Plug.Auth`, `context.actor` and `context.tenant` are always `nil` —
dispatch fails closed rather than trusting anything from the wire.

## Authentication is NOT authority (RFC-SA2A-001 S29)

Everything above establishes *who* the caller is. It says nothing about *what* that
caller may do — and in ash_a2a those are two separate, separately-configured
decisions.

A skill's real, compiled `AshA2A.Skill.consequence` decides which decision applies:

| consequence | what `AshA2A.CommandBus.admit/2` requires |
|---|---|
| `:observe` | nothing — admitted unconditionally, no authority needed |
| `:change`, `:external_do` | a real `AshA2A.Authority` that admits for this exact principal and capability |
| `:unknown` | refused (`:consequence_unclassified`) regardless of authority |

For the consequential classes, that `AshA2A.Authority` comes from
`AshA2A.Authority.Grant.authorize/3`, which asks the configured
`AshA2A.Authority.Broker` whether this principal holds a **standing grant for this
specific capability**. A verified Bearer token is necessary and not sufficient. Grants
are per `(principal, capability_id)` pair: granting `"create_note"` grants exactly
`"create_note"`, never `"destroy_note"`.

> Earlier releases had no grant step: the dispatch path synthesized an authority for
> whatever capability id the inbound message named, so any authenticated caller held
> authority for every skill on the agent card. That was a real privilege escalation
> and is what this model closes.

### Configure a broker and issue grants

```elixir
# config/config.exs — :broker is already the default, named here for clarity.
config :ash_a2a, :authority_policy, :broker
config :ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv
```

This is genuinely config-only (v26.9.17): `AshA2A.Application.start/2`
auto-starts a real `EKV` instance on the broker's behalf the same way it
already does for `config :ash_a2a, :receipt_store, AshA2A.ReceiptStore.Ekv`
— no separate supervision-tree change is needed, and choosing both configs
as `Ekv` at once starts two distinct instances, one per layer. Before this
fix that was not true (`Authority.Broker.Ekv`'s own moduledoc states it does
not start `EKV` itself); see `docs/explanation/v26.9.17-commandbus-scale.md`
for the real numbers behind choosing `Ekv` here at all — durability across a
restart, not scale: the same document's Authority Broker section measures
`Ekv` as ~1.7x–2.2x higher latency than `InMemory` at this specific,
read-heavy layer, with no throughput upside.

`AshA2A.Authority.Broker` is a behaviour with three shipped-in reference points:
`AshA2A.Authority.Broker.InMemory` (a real `GenServer`, single node, development and
tests), `AshA2A.Authority.Broker.Ekv` (durable across process and node restarts), and
your own implementation backed by whatever real identity system you already run.
Neither shipped broker is a production identity system or Sybil-resistant — read
their moduledocs before deploying one.

Start the broker in your supervision tree, then issue grants:

```elixir
subject = AshA2A.Identity.principal(%{id: "user-42", tenant: "acme"})
{:ok, _authority} = AshA2A.Authority.Grant.grant(subject, "create_note")

AshA2A.Authority.Grant.granted?(subject, "create_note")
#=> true
AshA2A.Authority.Grant.granted?(subject, "destroy_note")
#=> false
```

The grant subject must be built from the **same term** your `verify_callback/3`
returns as the identity — that whole term is what reaches the dispatch path as
`auth_identity`, and `AshA2A.Identity.principal/1` normalizes it identically on both
sides.

To take a grant away, revoke it through the broker; the next dispatch fails closed
with `:authority_required`:

```elixir
:ok = AshA2A.Authority.Broker.Ekv.revoke(authority)
```

### What an ungranted consequential call looks like

`AshA2A.CommandBus.admit/2` refuses before the Ash action runs at all — no record is
written, no external effect happens, and no receipt is committed. The refusal surfaces
the same way any dispatch failure does: a real `A2A.Task` whose own
`status.state` is `failed` (not a JSON-RPC-level error), carrying the typed
`:authority_required` refusal.

### Migrating an existing deployment

If you are upgrading an agent that relied on the old behavior and cannot wire a broker
yet, the pre-fix behavior is still available, explicitly:

```elixir
config :ash_a2a, :authority_policy, :transport_verified_grants_capability
```

This mode **violates RFC-SA2A-001 S29**: it gives every transport-authenticated caller
authority for every capability they name, including every `:change`/`:external_do`
skill. It logs a real warning naming the escalation on first use. Treat it as a
migration window, not a configuration.

Leaving `:authority_policy` at its `:broker` default with no `:authority_broker`
configured is the safe failure: every consequential dispatch is refused with
`:authority_required`, and a real warning names the missing configuration so the
refusals are never mysterious.


## 1. Define a `:verify` callback

`A2A.Plug.Auth.init/1` takes the security schemes your agent declares and a `:verify`
function of arity 3 (`scheme, credential, conn`). Return `{:ok, identity_map}` for a
valid credential, `{:error, reason}` otherwise:

```elixir
defp verify_callback("bearer_auth", "valid-token-42", _conn) do
  {:ok, %{id: "user-42", tenant: "acme"}}
end

defp verify_callback(_scheme, _credential, _conn), do: {:error, "invalid token"}
```

In production this looks up the bearer token in your real token store instead of
matching a literal string. The returned map's `:tenant` (or `"tenant"`) key is what
`ContextResolver` extracts as `context.tenant`; the whole map becomes `context.actor`.

## 2. Build the plug pipeline

Declare your security schemes, initialize `A2A.Plug.Auth` with them and your verify
callback, then chain into `A2A.Plug` pointed at your `AshA2A.Agent` module:

```elixir
@schemes %{"bearer_auth" => %A2A.SecurityScheme.HTTPAuth{scheme: "bearer"}}

auth_opts =
  A2A.Plug.Auth.init(
    schemes: @schemes,
    verify: &verify_callback/3
  )

plug_opts =
  A2A.Plug.init(
    agent: AuthProbeAgent,
    base_url: "http://localhost:4000/a2a"
  )

conn
|> A2A.Plug.Auth.call(auth_opts)
|> then(fn conn ->
  if conn.halted, do: conn, else: A2A.Plug.call(conn, plug_opts)
end)
```

`A2A.Plug.Auth.call/2` halts the conn with a `401` and `%{"error" => "Unauthorized"}`
body before `A2A.Plug` ever runs, both when the `Authorization` header is missing and
when `verify_callback/3` returns `{:error, _}` — checking `conn.halted` before chaining
into `A2A.Plug` is required, exactly as shown above.

## 3. Read identity in the Ash action

Nothing special is required in the action itself — `context.actor` and
`context.tenant` are already populated by the time your action's `run/2` (or any
other Ash action type) executes:

```elixir
action :whoami, :map do
  run(fn _input, context ->
    {:ok, %{actor: context.actor, tenant: context.tenant}}
  end)
end
```

With the `verify_callback/3` above and a request bearing
`Authorization: Bearer valid-token-42`, this action returns
`%{actor: %{id: "user-42", tenant: "acme"}, tenant: "acme"}` — the real assertion made
by `test/ash_a2a_plug_auth_test.exs`.

## 4. The `:ambiguous_skill` gotcha

`AshA2A.Agent.__dispatch__` picks a skill automatically only when the resource
exposes exactly one public action. `AshA2A.Info.capability_index/1` returning:

* zero skills → `{:error, {:no_skill, resource_or_domain}}`
* exactly one skill → dispatches to it implicitly
* two or more skills → `{:error, {:ambiguous_skill, resource_or_domain}}`

A resource with `defaults([:read])` plus one custom action (like `AuthProbe`'s
`:whoami` above) already has two public actions, so it hits the ambiguous case. Fix it
by setting `metadata["skill"]` explicitly on the outbound `A2A.Message`:

```elixir
message = %{A2A.Message.new_user([A2A.Part.Data.new(%{})]) | metadata: %{"skill" => "whoami"}}
```

`AshA2A.Agent.resolve_skill_name/2` reads `metadata["skill"]` (via
`AshA2A.MetadataKey.get/2`, so either the atom or string key works) before ever
falling back to the single-skill default, so an explicit skill name always
disambiguates regardless of how many public actions the resource has. Note that
`"skill"` here is a routing directive read from message metadata deliberately — it is
not `actor`/`tenant`, and `ContextResolver` never touches it.

## See also

* `AshA2A.Authority.Grant` — the grant decision, both policy modes, and why the
  fail-closed one is the default
* `AshA2A.Authority.Broker` — the broker behaviour, including the `granted?/3`
  contract a custom implementation must satisfy fail-closed
* `test/ash_a2a_authority_capability_grant_test.exs` — the real end-to-end tests this
  section is based on (ungranted refusal, granted actuation, per-capability scoping,
  revocation, `:observe` unaffected, replay preserved)
