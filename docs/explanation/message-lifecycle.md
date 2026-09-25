# Message Lifecycle

What actually happens to one request, from the wire to the receipt. This
is a narrative over the same facts the
[architecture](architecture.md) and
[reference](../reference/a2a-endpoint-contract.md) pages state — read
those for tables; read this for the shape.

## 1. Arrival

An HTTP request hits `A2A.Plug` (standalone Bandit or Phoenix `forward`).
Card discovery (`GET /.well-known/agent-card.json`) never touches Ash —
it is the compiled capability index projected by
`AshA2A.CapabilityIndex.AgentCardBuilder`. Everything else is a JSON-RPC
`message/send` or `message/stream` POST, always answered with HTTP 200
(transport auth failures excepted).

If `A2A.Plug.Auth` sits in front, it extracts a credential (Bearer, Basic,
API key, OAuth2/OIDC bearer), hands it to **your** `verify/3` callback,
and on success stores the identity map in `conn.private[:a2a][:auth]` —
on failure it halts 401 before the A2A plug runs at all. The plug merges
that identity into the call's `metadata["a2a.auth"]`, alongside the three
static/per-request/per-call metadata layers.

## 2. The agent process

`A2A.call/3` lands in the `A2A.Agent` GenServer that
`use AshA2A.Agent` generated — one mailbox per agent, so calls to one
agent serialize. The runtime creates/looks up the A2A task
(`task_id`/`context_id` give you multi-turn continuity) and invokes the
agent's `handle_message/2`, which is `AshA2A.Agent.__dispatch__/3`.

## 3. The two gates before skill resolution

`__dispatch__` first checks the semantic-request gates — both must be
true to divert to the semantic compiler: the resource/domain declared
`a2a do semantic_requests true end` **and** the caller's message metadata
sets `:semantic_request`/`"semantic_request"`. That route compiles the
message's text through `AshA2A.Semantic.Compiler` into a
candidate-fenced `ExecutionPackage` (standing `:candidate`, authority
`:none` — it can never DO), with a `:semantic_compilation_failed` typed
reply guarding the agent process from compiler raises. Everything else
falls through to ordinary skill resolution: `metadata[:skill]`, or the
implicit single-skill default (two or more exposed skills without
metadata → `:ambiguous_skill`).

## 4. Consequence routing

The resolved skill carries a compile-time `consequence` classification.
`:unknown` is refused outright (`:consequence_unclassified`) — a generic
`:action` does not run until its author classifies it. `:observe` (the
`:read` default) calls `AshA2A.Dispatcher.dispatch/6` directly. A
`:change`/`:external_do` skill instead builds an `AshA2A.Command` and
enters `AshA2A.CommandBus.run/4` — the receipted path.

Two details make the command real rather than decorative: `command_id` is
the message's own `message_id` (so a genuine client retry re-enters with
the same identity), and the command's fingerprint hashes the admitted
input plus the authority's deterministic `token_id` — so "same command"
is a content claim, not a label.

## 5. Admission (if consequential)

`CommandBus.admit/2` requires an `AshA2A.Authority` admitting this exact
principal and capability. The authority is decided per call by
`AshA2A.Authority.Grant.authorize/3`: the configured broker is asked
whether this principal holds a standing grant for this `capability_id`.
No broker configured or no grant → `:authority_required`, refused before
the Ash action runs, no receipt, no effect. Authentication never
substitutes for this (RFC-SA2A-001 S29). Before dispatch, the sole-DO
fence (`AshA2A.BrceAnchor`) also requires that a pending receipt anchor
bound to this exact capability was taken — a consequence-bearing action
cannot run outside the bus.

## 6. Claim, outbox, dispatch

The receipt store `claim/2`s the `command_id`: a fresh claim proceeds; an
identical fingerprint under the same id replays the stored receipt
instead of re-executing; a different fingerprint under the same id is a
`:command_conflict` refusal. A `:pending` receipt is journaled to the
filesystem `AshA2A.ReceiptOutbox` **before** dispatch, so a crash between
"decided" and "done" leaves admissible evidence rather than silence.

Then the bus calls the very same `Dispatcher.dispatch/6` an `:observe`
skill used. The dispatcher resolves actor/tenant through
`AshA2A.ContextResolver` — from `auth_identity` only, never from message
metadata — and runs the real Ash action (`for_read`/`for_create`/…).
A Data-part input map becomes the action input; results wrap back into
`Part.Data` (`%{results: [...]}` for lists, `%{result: v}` for scalars);
`missing_argument`-class failures return `{:input_required, _}` instead
of a hard error.

## 7. Commit and evidence

On success the bus commits the final `AshA2A.Receipt` (replacing the
pending outbox entry), telemetry fires
(`[:ash_a2a, :receipt, :committed]`, merged with the dispatch span into
one OCEL event if forwarding is on), and the reply maps to task state:
`:completed` with artifacts, `:input_required`, or `:failed`. After a
crash anywhere on the path, `AshA2A.Reconciliation` classifies the
left-behind evidence (durable-in-primary, replayed, compensated) from the
outbox + store — recovery is a classification over receipts, not a guess.

## 8. The knobs that change the story

- Receipt durability: default `ReceiptStore.Memory` is per-process-life;
  `Ekv` survives restarts (set a real `data_dir`).
- Authority: the broker you configure decides grants; revocation takes
  effect on the next admission — except on **async** paths, where your
  worker must re-verify (`ObanAuthority.verify_live!/3`; see
  [the async authority how-to](../how-to/verify-authority-on-async-paths.md)).
- `AshA2A.KillSwitch` is a class-level halt primitive started by the
  application; it is not consulted by admission (a host opt-in tool, not
  a silent gate).
