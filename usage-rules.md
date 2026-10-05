<!--
SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
SPDX-License-Identifier: MIT
-->

# Rules for working with AshA2A

## Understanding AshA2A

AshA2A is an Ash extension that projects canonical public Ash actions as A2A protocol
skills. Ash is the source of truth: `skill` declarations cannot create actions, cannot
change action arguments, and cannot expose `public?: false` actions. Read
`docs/how-to/authenticate-agent-requests.md` before wiring any inbound surface.

## Skill declarations

**Do** rely on zero-configuration projection: every action returned by
`Ash.Resource.Info.public_actions/1` is exposed automatically under `use Ash.Resource,
extensions: [AshA2A]`.

**Don't** declare a `skill` to manufacture a capability. The `skill` entity in
`AshA2A.Dsl` is an override locator for A2A-only metadata (display name, description,
tags) or suppression (`expose?: false`) on an already-public action. The referenced
action must already exist and be public.

```elixir
a2a do
  skill :search, :read do
    description "Search the catalog"
    tags ["catalog", "search"]
  end
end
```

**Don't** declare `argument` entities. They are accepted only for pre-v26.9.12 source
compatibility and are deliberately ignored by capability compilation; arguments are
derived from `Ash.Resource.Info` instead.

## Consequences (classify every mutating skill)

`consequence` is one of `:observe`, `:change`, `:external_do`, `:unknown`. Defaults:
generic `:action` skills sit on the fail-closed `:unknown`; on `:create`/`:update`/
`:destroy` actions the default is `:change`.

| consequence | what dispatch requires |
|---|---|
| `:observe` | nothing — admitted unconditionally; skips authority, admission and receipts |
| `:change` | a valid authority grant for this exact `(principal, capability)` |
| `:external_do` | a valid authority grant for this exact `(principal, capability)` |
| `:unknown` | refused (`:consequence_unclassified`) regardless of authority |

**Do** declare `consequence: :external_do` explicitly on any skill that performs an
external side-effecting actuation. **Don't** leave a side-effecting skill on the
fail-closed `:unknown` default — it is refused at dispatch.

**Don't** declare `consequence: :observe` on a mutating action: that is a compile-time
`DslError` (`observe_on_mutating_action`, SEC-04), because `:observe` skips authority,
admission and receipts.

**Do** use `on_cancel` (a module implementing `c:AshA2A.OnCancel.on_cancel/3`, or an
`{module, function, extra_args}` MFA) when a task under the skill can be genuinely
canceled and needs real Ash-side compensation. **Don't** assume cancellation runs
compensation for you — unset (the default) leaves cancellation telemetry-only.

## Authority is not authentication

**Do** treat identity and authority as two separate decisions. `AshA2A.Protocol.Plug.Auth`
verifies a real credential and produces `context.actor`/`context.tenant`. It says
nothing about what the caller may do.

**Don't** read `actor`/`tenant` out of the inbound message's own `metadata` — any caller
can put `%{"actor" => ...}` there, and `AshA2A.ContextResolver.from_a2a_message/4`
never trusts that field. The only path is: verified credential → `conn.private` →
`metadata["a2a.auth"]` → `context.actor`.

**Do** configure the fail-closed authority policy (the default):

```elixir
config :ash_a2a, :authority_policy, :broker
config :ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv
```

**Do** issue per-capability standing grants via `AshA2A.Authority.Grant.grant/3`.
Granting `"create_note"` grants exactly `"create_note"`, never `"destroy_note"`.
**Don't** reach for the `:transport_verified_grants_capability` migration policy
except as an explicit, temporary migration window: it gives every
transport-authenticated caller authority for every capability they name.

**Do** re-verify grants live at execution time on async paths (Oban delivery) — see
`docs/how-to/verify-authority-on-async-paths.md`. **Don't** rely on a grant checked
only at enqueue time: revocation must take effect before the next actuation, and the
next refusal is `:authority_required`, fail-closed.

**Don't** deploy the shipped brokers (`AshA2A.Authority.Broker.InMemory`,
`AshA2A.Authority.Broker.Ekv`) as a production identity system: neither is
Sybil-resistant. Back the `AshA2A.Authority.Broker` behaviour with your real identity
system.

## Transports and the auth pipeline

**Do** chain the auth plug in front of the transport and check `conn.halted`:

```elixir
conn
|> AshA2A.Protocol.Plug.Auth.call(auth_opts)
|> then(fn conn ->
  if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
end
```

**Don't** build agents that trust token payloads: OAuth2/OIDC schemes only extract the
bearer string. No JWKS fetch, introspection, audience or signature check ships with the
library — your `verify/3` callback is the whole verification story. Declaring
`%AshA2A.Protocol.SecurityScheme.MutualTLS{}` extracts nothing: it returns
`:unsupported` (401).

## Skill routing

**Do** set `metadata["skill"]` on inbound messages when the target exposes more than one
public action. With zero public actions dispatch fails `{:no_skill, _}`; with exactly
one it routes implicitly; with two or more it fails `{:ambiguous_skill, _}` unless
`metadata["skill"]` disambiguates (read via `AshA2A.MetadataKey`, atom or string key).

**Don't** confuse `"skill"` metadata (a routing directive) with `actor`/`tenant`
(identity — never read from message metadata).

## Semantic requests: two gates, never a fallback

**Do** enable semantic compilation only as an explicit production surface: set
`semantic_requests: true` in the `a2a` block AND have the caller set
`metadata[:semantic_request]` (or the string key). **Don't** expect unrecognized skill
names or free text to ever reach `AshA2A.Semantic.Compiler` — both gates must be true,
by design.

## Compile-time enforcement

**Do** let the verifiers refuse bad declarations at compile time. `AshA2A.Verifiers.VerifySkills`
fails with `REFUSED_ACTION_NOT_FOUND` / `REFUSED_ACTION_NOT_PUBLIC` (unknown or
non-public action), `refused_argument_mapping_target` (`argument_mapping` target that is
not a real action argument), `refused_type_not_json_serializable` (unknown custom types
warn), and `refused_lease_required_no_authorizer` (`lease_required?: true` without a
lease-capable authorizer). Fix the declaration, don't fight the verifier.

## Non-negotiables

| Rule |
|---|
| Ash is the source of truth; `skill` cannot manufacture capability |
| `:observe` skips authority, admission and receipts — declare it only on reads |
| `:unknown` consequence is refused unconditionally (fail closed) |
| Identity from verified credentials only, never from message metadata |
| Authority is a per-`(principal, capability)` standing grant, revocable |
| Semantic compilation is opt-in via two gates, never a silent fallback |

## See Also

- `docs/how-to/authenticate-agent-requests.md` — the real auth + grant walkthrough
- `docs/how-to/verify-authority-on-async-paths.md` — async revocation
- `docs/reference/mix-tasks.md` — `mix ash_a2a.install` emits a marker-checked copy
  of these rules into your project
- `mix usage_rules.sync AGENTS.md --all` (the `usage_rules` package) — combine these
  rules into your own agent rules file
