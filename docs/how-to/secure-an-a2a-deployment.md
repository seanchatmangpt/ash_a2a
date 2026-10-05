# How to secure an A2A deployment

This guide consolidates the security surface ash_a2a actually ships, and where each
control lives in code. Every claim below is grounded in the current tree; the cited
court files are executable and each exits 0 on conformance.

## Who this is for

You are mounting `AshA2A.A2ATransport.Plug` (or the base `AshA2A.Protocol.Plug`) on a
real listener and need to know: what authenticates a caller, what a caller can see,
what the server refuses, and what you still must configure yourself.

## 1. Authenticate every request (the plug does not do it for you)

Problem: the base plug serves the agent card and JSON-RPC without any credential
check. An unauthenticated deployment has no owner scoping at all — every caller is
`:anonymous` and ownership checks pass for nobody's tasks but fail closed for
everybody's.

Steps:

1. Mount `AshA2A.Protocol.Plug.Auth` in your pipeline, before the A2A plug:
   (`lib/ash_a2a/protocol/plug/auth.ex`)

   ```elixir
   plug AshA2A.Protocol.Plug.Auth,
     schemes: %{
       "bearer_auth" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}
     },
     verify: &MyApp.Auth.verify_a2a/3
   ```

2. Implement the `verify/3` contract:
   `(scheme_name, credential, conn) -> {:ok, identity_map} | {:error, reason}`.
   The credential is a binary for bearer, API key, OAuth2 and OpenID Connect
   schemes, and `{username, password}` for HTTP Basic. Supported scheme structs:
   `HTTPAuth` (bearer/basic), `APIKey` (header/query/cookie), `OAuth2`,
   `OpenIDConnect`; `MutualTLS` extraction answers `:unsupported` (terminate mTLS at
   your proxy and authenticate the extracted identity instead).

3. Compose requirements with the `:security` option. Each map is an AND (every
   scheme in the map must verify); the list is an OR (the first fully-satisfied
   alternative wins). Default: each scheme is an independent alternative.

4. Rely on the fail-closed behavior: a `verify/3` that raises is rescued and
   answered as the generic 401 envelope (`{"error" => "Unauthorized"}`), never a
   500 with the exception text. On refusal the plug appends one `WWW-Authenticate`
   challenge per scheme that has a standard challenge form (RFC 7235 §3.1 allows
   multiple challenges); API-key and mTLS schemes contribute none.

5. Review the defaults: `:exempt_paths` exempts only
   `[[".well-known", "agent-card.json"]]`, and `:realm` defaults to `"a2a"`.

Evidence: `test/ash_a2a_v1_auth_challenge_test.exs` — the auth-challenge companion
court listed in `docs/reference/a2a-v1-conformance.md`.

## 2. Scope every task surface to its owner

Problem: once callers are authenticated they must not see or act on each other's
tasks, and a caller must not be able to *claim* ownership by writing metadata.

Steps:

1. Understand the derivation. Ownership of a task is
   `AshA2A.Transport.Runtime.owner/1`: the recorded `"ash_a2a.owner"` metadata key
   recorded at task creation, else the principal derived from the verified
   `"a2a.auth"` identity via `AshA2A.Transport.Principal.key/1` — an atom-keyed
   shape a JSON caller cannot forge from request metadata.

2. Expect `-32001` for foreign tasks. `AshA2A.A2ATransport.Ownership.fetch/3`
   answers `{:error, :not_found}` for a task the verified caller does not own, and
   the plug renders it exactly like a missing task (`Error.task_not_found/0`,
   -32001). Existence of a foreign task is not revealed.

3. Both task surfaces are scoped on the owned transport:

   - `tasks/list` is answered by the owner-scoped
     `{:ash_a2a_list_tasks, principal, params}` agent call (the `SEC-01` clause in
     `lib/ash_a2a/a2a_transport/plug.ex`); delegating it unscoped was the hole this
     clause closes. A bare `AshA2A.Protocol.Agent` without the clause falls back to
     the delegate (documented unscoped behavior).
   - `tasks/resubscribe` passes the caller principal into
     `AshA2A.A2ATransport.SSE.resubscribe/6`, which fetches through
     `Ownership.fetch/3` — a foreign task is -32001 there too.

4. Metadata forgery is refused upstream: `Ownership.sanitize_params/1` drops
   `"a2a.auth"`, `"ash_a2a.owner"` and `:stream` from every request's
   `params.metadata` before routing (`AshA2A.A2ATransport.Plug.route/3` calls it on
   every decoded request). A caller can neither overwrite the verified identity nor
   self-assign an owner key.

Evidence: `test/ash_a2a_v1_owner_scope_test.exs` and the transport court's
`SEC-01 task ownership over real HTTP with two real bearer principals` block in
`test/ash_a2a/transport/transport_court_test.exs`.

## 3. Keep credentials off the wire (stripping paths)

Problem: the verified identity lands in `task.metadata["a2a.auth"]` and can carry
the raw credential; any payload echoed back — task responses, SSE frames, webhook
bodies, extended cards — would leak it.

Steps:

1. Know the three internal keys stripped everywhere:
   `["a2a.auth", "ash_a2a.owner", :stream]`
   (`AshA2A.A2ATransport.Ownership.@internal_keys`).

2. Every publish path strips before it encodes:

   - Task JSON responses: `register_before_send` + `strip_result/1` ->
     `Ownership.strip_wire/1` on the delegated response.
   - SSE snapshots: `SSE.encode_task/1` -> `Ownership.strip_task/1`.
   - Webhook bodies: `publish_result/4` strips via `strip_wire/1` *before*
     `TaskEvents.publish/5`; `PushDelivery` POSTs that already-stripped payload.
   - Extended cards: `ExtendedCard.strip_internal_keys/1` recursively drops the
     keys from every map in the provider's card, so a credential nested in
     `skills` or metadata cannot leak.

3. Do not build side channels that bypass `TaskEvents.publish/5` or
   `strip_result/1` — the strip happens at publish time, so a payload handed to a
   subscriber or webhook receiver directly is not covered.

## 4. Harden the wire input path

Problem: request bodies, webhook URLs and error text are three ways internal detail
or internal network reach leaves the process.

Steps:

1. Cap body size. The standalone `AshA2A.Transport.Plug` HTTP+JSON surface refuses
   bodies over `:max_body_bytes` (default 1_000_000) with 400
   `invalid_request("Body too large")` (`lib/ash_a2a/transport/http_json.ex`).
   The owned transport wrapper reads with `Plug.Conn.read_body/2` and answers a
   body that overflows the read limit with the JSON-RPC parse error
   ("Body too large") instead of buffering it
   (`lib/ash_a2a/a2a_transport/plug.ex`, `read_json/1`).

2. Admit webhook URLs through `AshA2A.A2ATransport.WebhookPolicy.admit/2`. It fails
   closed: `https` only (`http` only with `allow_http: true`), no userinfo, host
   must resolve, and **every** resolved A/AAAA address must be public — loopback,
   RFC 1918, CGNAT, link-local, multicast, reserved, IPv6 ULA/link-local,
   IPv4-mapped forms, and the tunnel/translate prefixes (NAT64, Teredo, 6to4) are
   refused unless an explicit `allow_cidrs` entry covers the address. The admitted
   result carries the resolved addresses and `AshA2A.A2ATransport.PushDelivery`
   connects to exactly the admitted address (closing the DNS-rebinding window);
   delivery re-admits on every attempt.

3. Expect typed refusals, not prose. A2A-specific errors (-32001..-32009) serialize
   a `google.rpc.ErrorInfo` object inside the `data` array
   (`lib/ash_a2a/protocol/jsonrpc/error.ex`); -32602 carries an
   `ErrorInfo` with reason `INVALID_PARAMS`.

4. Keep the no-inspect error discipline. `AshA2A.Transport.SafeError.redact/1`
   replaces internal exception text, data-layer detail and `inspect/1` of arbitrary
   reasons with a typed code plus an opaque server-side correlation `ref`; the
   caller-actionable Ash `:forbidden`/`:invalid` classes keep their message. The
   switch `config :ash_a2a, :expose_error_detail, true` restores verbatim detail —
   development only, default `false`. This is why the SSE error path in
   `stream_message/6` renders `SafeError.redact(reason)` rather than `inspect`:
   an earlier form leaked `task.metadata["a2a.auth"]` through
   `{:not_streaming, task}` into the -32603 data (the `SEC-08` note in
   `lib/ash_a2a/a2a_transport/sse.ex`).

## 5. Sign and cache agent cards

Problem: a client that fetches `/.well-known/agent-card.json` over an untrusted
path cannot tell a tampered card from a genuine one, and re-fetching on every call
wastes a round trip.

Steps:

1. Sign the card server-side before serving:
   `AshA2A.Protocol.CardSigning.sign/3` canonicalizes the **wire-projected** card
   (RFC 8785 JCS over the `encode_agent_card/2` output, `signatures` removed) and
   appends a detached compact JWS (HS256) entry to `card.signatures`.

2. Verify on discover, client-side: pass `verify_card_signature: key` to
   `AshA2A.Protocol.Client.new/2` or `discover/2`; the decoded card's `signatures`
   entries are checked via `CardSigning.verify/2` before the card is trusted
   (`lib/ash_a2a/protocol/client.ex`, `admit_card/2`). `verify/2` verifies every
   entry, distinguishes key failure (`:bad_signature`) from content tampering
   (`:digest_mismatch`), and refuses an empty `signatures` list as
   `{:error, {:malformed, :no_signatures}}` — no vacuous all-verified admission.

3. Cache discovery with `AshA2A.Protocol.CardCache.fetch/2`: on-disk, one JSON file
   per card URL; honors `ETag`/`If-None-Match` (falling back to
   `If-Modified-Since`) per A2A v1.0 §8.6, returns `:fresh`/`:cached`/
   `:not_modified`/`:stale`, applies a 300-second default max-age when the server
   sends no caching headers, and serves the cached card when revalidation fails.

## 6. Bound admission before any task is created

Problem: an unbounded transport turns any caller into a capacity DoS.

Steps:

1. Configure the agent-level admission limits
   (`AshA2A.Transport.Runtime`, `config :ash_a2a, :execution` or per-agent
   `use AshA2A.Agent, execution: [...]`):

   - `max_in_flight` (default 256) — global ceiling; over the limit refuses
     `%{code: :server_busy}` (-32000) before any task exists.
   - `rate_limit: {count, per_ms}` — optional per-principal token bucket, default
     off; refusal `%{code: :rate_limited}` (-32000). Both checks run before task
     creation.

2. Configure the transport runtime ceilings (`AshA2A.A2ATransport` options):
   `:max_children` (default 1024) caps concurrent SSE stream pumps;
   `:max_deliveries` (default 256) caps concurrent webhook deliveries on their own
   supervisor, so a slow webhook receiver cannot starve `message/stream`;
   `:max_per_task` (default 16) caps push configs per task; `:max_events`
   (default 10_000) caps the per-task event log. All state is node-local and
   in-memory.

3. `push_notifications` defaults to `false` on the owned plug and answers
   -32003 until you enable it with a `push: [signing_secret: ...]` transport —
   nothing is half-enabled.

Evidence: the transport court's `SEC-03` blocks assert real `-32000`
`server_busy`/`rate_limited` bodies, and `SEC-05 unauthenticated callers fail
closed`, in `test/ash_a2a/transport/transport_court_test.exs`.

## Hardening checklist

- [ ] `AshA2A.Protocol.Plug.Auth` mounted with a real `verify/3`; no default-credential
      or always-true verifier.
- [ ] `:security` requirements reviewed — AND-groups where one credential is not enough.
- [ ] `:exempt_paths` still only the agent card (or narrower).
- [ ] Consequence-bearing skills require real `AshA2A.Authority` grants (authentication
      is not authority; see
      [Authenticate agent requests](authenticate-agent-requests.md)).
- [ ] `tasks/list`, `tasks/get`, `tasks/cancel`, `tasks/resubscribe` exercised with two
      principals to confirm -32001 scoping (or you accept and document the bare
      protocol agent's unscoped `tasks/list` fallback).
- [ ] No custom publish path bypasses `TaskEvents.publish/5` / `strip_result/1`.
- [ ] Extended-card provider output treated as untrusted (the recursive strip is a
      backstop, not a license).
- [ ] Body caps set deliberately: `:max_body_bytes` on the HTTP+JSON surface;
      wrapper behind a proxy with a body limit if the default read limit is not what
      you want.
- [ ] `WebhookPolicy` `allow_http: false` and `allow_cidrs: []` unless you have a
      named, reviewed reason.
- [ ] `:expose_error_detail` left `false` in production.
- [ ] Cards signed with `CardSigning.sign/3`; clients pass `verify_card_signature:`.
- [ ] `max_in_flight` and `rate_limit` set to real capacity numbers, not defaults.
- [ ] `max_deliveries` and `max_children` sized for your webhook receiver's worst case.
- [ ] `push_notifications` left off unless push delivery is actually used.

## See also

- [Authenticate agent requests](authenticate-agent-requests.md)
- [Verify authority on async paths](verify-authority-on-async-paths.md)
- [A2A endpoint contract](../reference/a2a-endpoint-contract.md)
- [A2A v1.0 conformance statement](../reference/a2a-v1-conformance.md)
