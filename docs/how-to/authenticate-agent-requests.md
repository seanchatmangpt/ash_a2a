# How to authenticate inbound A2A requests and thread identity into your Ash actions

This guide wires a real `AshA2A.Protocol.Plug.Auth` in front of a real `AshA2A.Protocol.Plug`, so a Bearer
credential on an inbound A2A request becomes `context.actor`/`context.tenant` inside
your Ash action. It is based directly on the working end-to-end test
`test/ash_a2a_plug_auth_test.exs` and the trust-boundary code in
`lib/ash_a2a/context_resolver.ex` — every snippet below matches that real code.

## The trust boundary you need to understand first

`AshA2A.ContextResolver.from_a2a_message/4` never reads `actor`/`tenant` out of the
inbound `AshA2A.Protocol.Message`'s own `metadata` field. That field is unauthenticated JSON-RPC
request body content — any caller can put `%{"actor" => %{"id" => "admin"}}` in it.
The only path an actor/tenant can take into your action is:

1. `AshA2A.Protocol.Plug.Auth` verifies a real credential and stores the result in
   `conn.private[:a2a][:auth]`.
2. `AshA2A.Protocol.Plug` merges that into the call's `metadata["a2a.auth"]`.
3. `AshA2A.Agent.__dispatch__` reads `metadata["a2a.auth"][:identity]` and passes it
   to `AshA2A.Dispatcher.dispatch/6` as `auth_identity`.
4. `AshA2A.ContextResolver.from_a2a_message/4` sets `context.actor` to that
   `auth_identity` verbatim, and `context.tenant` to `auth_identity[:tenant]` (or the
   string-keyed `"tenant"`), or `nil` if the caller never wired auth at all.

If you skip `AshA2A.Protocol.Plug.Auth`, `context.actor` and `context.tenant` are always `nil` —
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
not start `EKV` itself); see `docs/archive/reports/v26.9.17-commandbus-scale.md`
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

To take a grant away, revoke it through `Grant` — the symmetric counterpart
of `grant/3`, keyed on the same deterministic token id `authorize/3` looks
up — and the next dispatch fails closed with `:authority_required`:

```elixir
:ok = AshA2A.Authority.Grant.revoke(subject, "create_note")
```

`Grant.renew/3` extends or shortens a standing grant's `expires_at` in
place, and `Grant.list_grants/2` enumerates what a principal currently
holds (both degrade to a named `:error` when the configured broker doesn't
implement the optional callbacks). Every decision and lifecycle transition
is observable as telemetry — `[:ash_a2a, :authority, :decision]` and
`[:ash_a2a, :authority, :grant, :issue | :revoke | :renew]` — so "did the
revocation take effect" is answered from your telemetry backend, not by
waiting for the next refusal (see the
[telemetry reference](../reference/telemetry.md)).

> If a command can reach your action through an **async** path (Oban
> delivery), revocation needs one more step: your worker must re-verify
> the grant live at execution time — see
> [Verify authority on async paths](verify-authority-on-async-paths.md).

### What an ungranted consequential call looks like

`AshA2A.CommandBus.admit/2` refuses before the Ash action runs at all — no record is
written, no external effect happens, and no receipt is committed. The refusal surfaces
the same way any dispatch failure does: a real `AshA2A.Protocol.Task` whose own
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

`AshA2A.Protocol.Plug.Auth.init/1` takes the security schemes your agent declares and a `:verify`
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

Declare your security schemes, initialize `AshA2A.Protocol.Plug.Auth` with them and your verify
callback, then chain into `AshA2A.Protocol.Plug` pointed at your `AshA2A.Agent` module:

```elixir
@schemes %{"bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

auth_opts =
  AshA2A.Protocol.Plug.Auth.init(
    schemes: @schemes,
    verify: &verify_callback/3
  )

plug_opts =
  AshA2A.Protocol.Plug.init(
    agent: AuthProbeAgent,
    base_url: "http://localhost:4000/a2a"
  )

conn
|> AshA2A.Protocol.Plug.Auth.call(auth_opts)
|> then(fn conn ->
  if conn.halted, do: conn, else: AshA2A.Protocol.Plug.call(conn, plug_opts)
end)
```

`AshA2A.Protocol.Plug.Auth.call/2` halts the conn with a `401` and `%{"error" => "Unauthorized"}`
body before `AshA2A.Protocol.Plug` ever runs, both when the `Authorization` header is missing and
when `verify_callback/3` returns `{:error, _}` — checking `conn.halted` before chaining
into `AshA2A.Protocol.Plug` is required, exactly as shown above.

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
by setting `metadata["skill"]` explicitly on the outbound `AshA2A.Protocol.Message`:

```elixir
message = %{AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})]) | metadata: %{"skill" => "whoami"}}
```

The agent reads `metadata["skill"]` at skill resolution (via
`AshA2A.MetadataKey.get/2`, so either the atom or string key works) before ever
falling back to the single-skill default, so an explicit skill name always
disambiguates regardless of how many public actions the resource has. Note that
`"skill"` here is a routing directive read from message metadata deliberately — it is
not `actor`/`tenant`, and `ContextResolver` never touches it.

## 5. Use the shipped validators: `SecurityValidators.verifier/1`

You do not have to hand-write token validation.
`AshA2A.Protocol.Plug.SecurityValidators` (with `AshA2A.Protocol.Plug.JWTVerifier`)
ships HS256/RS256 JWT verification, JWKS fetch and caching, OIDC discovery,
OAuth2 introspection, API-key and mTLS checks. `verifier/1` builds the `verify/3`
callback from a map of per-scheme configs keyed by scheme NAME:

```elixir
verify =
  AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
    "bearer_auth" => [secret: "s3cret", issuer: "https://auth.example.com"],
    "api_key" => [kind: :key, keys: ["k-123"]],
    "oidc" => [kind: :oidc, discovery: "https://idp.example.com/.well-known/openid-configuration"]
  })
```

`:kind` is `:bearer` (default), `:key`, `:oauth2`, `:oidc` or `:mtls`. A scheme
name with no config entry is refused fail-closed (`:unconfigured_scheme`).
For OAuth2 configs without a JWKS source, `:oauth2_metadata_url` (RFC 8414) is
used to discover `jwks_uri`.

### Scope enforcement

Scopes declared in a security requirement are enforced, not just advertised.
With `security: [%{"oauth" => ["notes.read"]}]`, `Auth` assigns the
requirement's scopes to `conn.assigns[:a2a_required_scopes]` before calling
`verify/3`. `SecurityValidators.verifier/1` uses them as `:required_scopes`
whenever the scheme's config has no explicit `:required_scopes` (explicit
config wins). A token lacking a declared scope is answered with `403` and
`WWW-Authenticate: Bearer realm="a2a", error="insufficient_scope", scope="..."`.
A custom `verify/3` signals the same outcome by returning
`{:error, %{code: :insufficient_scope}}` and may read the scopes from
`conn.assigns[:a2a_required_scopes]`.

### Keeping the card and the plug consistent

`AshA2A.Protocol.Plug.Auth.card_security/1` takes the same options as the plug
and returns `{security_schemes, security}`, ready to splice into your card
builder, so what the card advertises is exactly what the plug enforces.
`AshA2A.Authority.SecurityPreflight.check_card_security/1` verifies every name
in the card's `security` and each skill's `security_requirements` exists in
`security_schemes`.

## 6. Extended agent card behind authentication

The public card at `/.well-known/agent-card.json` is exempt from `Auth`. Data
you only want authenticated callers to see belongs in the extended card,
served by the extended-card provider (`:extended_card`) behind the same
`Auth` plug: `Auth` runs first, so the provider is only reached with a
verified identity in `conn.private[:a2a][:auth]`.

## 7. In-task `auth_required` and resume

When a skill needs a credential mid-task (for example a delegated OAuth
grant), the task moves to the `auth_required` state instead of failing. The
client obtains the credential out of band and sends a follow-up message on the
same task id; the transport-level `Auth` check still applies to that message,
so resume is authenticated like any other call.

## 8. Declaring OAuth flows

OAuth2 schemes declare their flows with typed structs from
`AshA2A.Protocol.SecurityScheme` (owned by the security-scheme module): the
authorization-code flow (`pkce_required: true` for PKCE), client credentials,
and device code (`device_authorization_url`, `token_url`, `scopes`). Declared
scope names are the ones your `security` requirements reference and the ones
step "Scope enforcement" checks.

## 9. Mutual TLS

For a `%MutualTLS{}` scheme, `Auth` reads the client certificate from the TLS
socket (`Plug.Conn.get_peer_data(conn).ssl_cert`, DER). Terminate TLS in the
Elixir server with `verify: :verify_peer` and `fail_if_no_peer_cert: true`.
Behind a trusted proxy that forwards the certificate, opt in explicitly:

```elixir
plug AshA2A.Protocol.Plug.Auth,
  schemes: %{"mtls" => %AshA2A.Protocol.SecurityScheme.MutualTLS{}},
  mtls_header: "x-client-cert",
  verify: AshA2A.Protocol.Plug.SecurityValidators.verifier(%{
    "mtls" => [kind: :mtls, fingerprints: ["ab12..."], san_allowlist: ["agent.example.com"]]
  })
```

`:mtls_header` is off by default; the header is accepted as a URL-encoded PEM
or a bare hex SHA-256 fingerprint and must only be enabled when the proxy
strips client-supplied copies. The `:mtls` validator admits a certificate whose
SHA-256 fingerprint is in `:fingerprints` or whose SAN (DNS, email, URI) is in
`:san_allowlist`; with neither configured it refuses fail-closed. With no
certificate and no `:mtls_header`, the scheme yields `:unsupported` (401).

## What the plug does NOT do for you

- **Digest and unknown HTTP schemes are unsupported**: an `HTTPAuth` scheme
  other than `bearer`/`basic` extracts `:unsupported` and the request gets a
  401; it is never misread as a bearer token.
- **mTLS without configuration is unusable**: with no peer certificate and no
  `:mtls_header`, a `MutualTLS` scheme extracts `:unsupported` (401). See
  "Mutual TLS" below.
- **The shipped brokers are reference implementations**: neither
  `InMemory` nor `Ekv` is Sybil-resistant or an identity system; production
  wants a broker backed by your real one.

## Identity canonicalizer rejections (RFC-SA2A-007 E-F)

`AshA2A.Identity.Canonical` (`lib/ash_a2a/identity/canonical.ex`) validates a
term in `AshA2A.Identity.Canonical.Encodable` before JCS (RFC 8785) hashing;
the first failure returns `{:error, code}` and nothing is hashed. Checks run
in this order per value (source: `identity/canonical/encodable.ex`):

| Code | Rejected input |
| --- | --- |
| `:canonical_depth_exceeded` | nesting deeper than 32 |
| `:canonical_integer_out_of_range` | integer with absolute value above 2^53 - 1 |
| `:canonical_invalid_utf8` | binary that is not valid UTF-8 |
| `:canonical_float_forbidden` | any float |
| `:canonical_key_type_forbidden` | map key that is neither binary nor atom |
| `:canonical_key_collision` | keys equal after `to_string/1` (atom and string key collide) |
| `:canonical_type_forbidden` | any other term (tuple, pid, ref, function) |
| `:canonical_size_exceeded` | canonical bytes above 1_048_576 (checked after encoding) |

Integers above 2^53 - 1 are rejected here, not converted to decimal strings as
the errata text restates `(unverified: errata policy differs from code)`.
NFC normalization is not performed in the normalizer. Map keys are
stringified by `AshA2A.Identity.Canonical.Normalizer`.

## See also

* `AshA2A.Authority.Grant` — the grant decision, both policy modes, and why the
  fail-closed one is the default
* `AshA2A.Authority.Broker` — the broker behaviour, including the `granted?/3`
  contract a custom implementation must satisfy fail-closed
* `test/ash_a2a_authority_capability_grant_test.exs` — the real end-to-end tests this
  section is based on (ungranted refusal, granted actuation, per-capability scoping,
  revocation, `:observe` unaffected, replay preserved)
