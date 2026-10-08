# _RESOLUTIONS

Integration-time resolutions ledger for the v26.10.3 v1-protocol fan-out (lanes over one
canonical checkout, `/Users/sac/ash_a2a`). Base: HEAD `5a84d88` (main). Tree state at ledger
time: dirty across `lib/`, `test/`, `docs/`; `lib/ash_a2a/protocol/` is entirely UNTRACKED
(`?? lib/ash_a2a/protocol/`), so no git diff exists for anything inside it — claims about the
prior state of that surface are SESSION-sourced, everything else is OBSERVED.
Evidence labels: OBSERVED = read from the tree at file:line; SESSION = session/coordinator
testimony, cited only where the tree cannot contradict it.
Last Updated: 2026-10-04.

## Contents

- 1. Ownership conflicts
- 2. Cross-lane unblocks
- 3. Clause-order finding (kill-leg root cause)
- 4. Codec hardening
- 5. Stream artifact-id threading
- 6. Open items at ledger time
- 7. Post-M7 wave resolutions (waves 2/3)
- See Also

## 1. Ownership conflicts

### 1.1 `lib/ash_a2a/protocol/client.ex` double-assigned

- Conflict: `client.ex` was assigned to two lanes at once — the client HTTP+JSON interop lane
  and the client card-verify lane. Violates the one-owner-per-file-per-wave rule
  (see `docs/jira/v26.9.28-kernel/_LANES.md` ground rule 2).
- Resolution: sequential landing into one file, disjoint by function surface, no hunk
  splicing. Both surfaces are present and independent:
  - card-verify lane: `discover/2` verify-key plumbing (`client.ex:214-235`), the fail-closed
    `admit_card/2` gate (`client.ex:240-252`, wraps `CardSigning.verify/2` at `:246`; a card
    served without signatures is refused, so all-verified-over-zero is impossible), and the
    struct field `verify_card_signature` (`client.ex:105,109`).
  - HTTP+JSON interop lane: `transport: :http_json` mode (`client.ex:97,109,137-139`),
    `http_json_send_message/3` (`client.ex:689`), `http_json_get_task/3` (`client.ex:716`),
    `http_json_cancel_task/3` (`client.ex:746`), and the §5.4 ErrorInfo error mapping
    (`client.ex:768-810`).
- Standing: PARTIAL_ALIVE as a resolution — the code is landed and compiles, but this
  conflict should be recorded in the next wave's `_LANES.md` so the file is single-owner.

## 2. Cross-lane unblocks

Edits made outside a lane's declared ownership to keep dependent lanes unblocked. All
OBSERVED in the tree.

### 2.1 `protocol/agent_card.ex` defstruct reorder (client lane, unblocking card consumers)

- `@protocol_version` hoisted above the `defstruct` (`agent_card.ex:82`, default applied at
  `:94`) — the single source of truth is `AshA2A.Protocol.Version.protocol_version/0`
  (`agent_card.ex:80-81` comment).
- `:preferred_transport` present in the struct (`agent_card.ex:73,93`).
- Struct SHAPE unchanged: pinned by `test/ash_a2a/capability_index_agent_card_shape_test.exs`
  — field inventory (`:39-40,:51-65`), `:preferred_transport` membership (`:71-72`), and the
  `protocol_version == "1.0"` Version-module default (`:75-79`).
- Known codec gap documented in the struct's own `@moduledoc` (`agent_card.ex:18-23`):
  neither `encode_agent_card/2` nor `decode_agent_card/1` reads or emits
  `preferredTransport` yet — it does not survive a wire round-trip.

### 2.2 `transport_court_test.exs` bind-then-pin conversion (test lane)

- Problem (invalid Elixir): `task_not_found_info/0` / `task_not_cancelable_info/0` were
  called inside match patterns (`%{... ^task_not_found_info() ...}` is not valid Elixir —
  a pin must bind to an existing variable).
- Resolution: bind on its own line, pin with `^var`. Helpers at
  `test/ash_a2a/transport/transport_court_test.exs:189-193`; bind+pin sites at `:269` +
  `:270-271` and `:597` + `:598-599`. Assertion semantics unchanged (same ErrorInfo maps
  asserted).
- Standing: the file compiles and the assertions are the same shape as before conversion.

### 2.3 `transport/plug.ex` stringify struct clause (coordinator)

- Problem: `AgentExtension` structs hit the generic `stringify(%{} = map)` clause, which
  calls `Map.new/2` over the struct — a struct is not Enumerable, so it crashes.
- Resolution: a first-clause `stringify(%AshA2A.Protocol.AgentExtension{} = ext)` that
  encodes via the codec before the map clause can match (`transport/plug.ex:140`).
- Integration residue (OPEN): a second `defp stringify(%AshA2A.Protocol.AgentExtension{})`
  clause at `transport/plug.ex:144-145` (`Map.from_struct` variant) is dead — unreachable
  behind `:140` and carrying a stale comment (`:141-143`). Note `mix compile
  --warnings-as-errors` exits 0 (see 6), so the residue is silent, not a build break.

## 3. Clause-order finding (kill-leg root cause)

- Root cause (OBSERVED, `transport/runtime.ex:274-283` comment + code): `use AshA2A.Agent`
  expands `use AshA2A.Protocol.Agent` first, so the ported agent's own
  `handle_info({:DOWN, ...})` clause (`protocol/agent.ex:450`, subscriber cleanup keyed on
  the agent's `:ash_a2a_protocol_task_workers` table) precedes the generated catch-all
  wrapper in clause order. That table never holds a transport worker, so every transport
  worker `DOWN` was consumed as an unknown-subscriber departure — the kill-leg (worker
  death) never failed the task. No clause this module (or the generated agent) defines can
  be ordered ahead of it.
- Watcher fix: `transport/runtime.ex:291-302` — a one-shot watcher re-delivers a non-`:normal`
  worker exit as the very same `{:ash_a2a_task_done, token, reply}` envelope the worker
  itself sends (`:300`), so the primary handler at `:309-318` fails the task with the typed
  `internal_error` (`:324-325`) and replies to the caller. `:normal` is ignored (`:295-296`).
  The protocol agent's own generated DOWN path (`protocol/agent.ex:445-462`) is untouched.
- F2's super-fallback suggestion REJECTED. Two grounds:
  1. It would raise: `GenServer`'s default `handle_info/2` is a behaviour default, not a
     `defoverridable` function — once any clause is defined, `super` has nothing to dispatch
     to and raises `FunctionClauseError` (SESSION-sourced mechanics; consistent with the
     tree, which defines clauses at every layer).
  2. It is the documented deprecation: `transport/runtime.ex:334-336` states calling `super`
     for a GenServer callback is deprecated; the generated wrapper routes unhandled messages
     to `unexpected_info/3` (`:337-344`) instead.

## 4. Codec hardening (coordinator)

- `encode_agent_extensions/1` now `List.wrap/1`s its input (`protocol/json.ex:659-661`) — a
  single struct or nil can never reach `Enum.map/2`.
- `encode_agent_extension/1` is public (`@doc false`, `protocol/json.ex:663-664`) with a
  struct clause (`:664-668`) and a plain-map clause (`:672-677`, builder opts / attach paths
  encode identically). Consumers: `transport/plug.ex:140` and
  `semantic/extension.ex:23-25`.
- `merge_extension_declarations/3` (`protocol/plug.ex:251-275`): card-seeding fix — a bare
  `%{}` seed silently dropped the capability index's default capabilities (streaming /
  push / extendedAgentCard) whenever `:extensions` was set; the card's own capabilities are
  now the seed when opts carry none (`:259-263`). `existing` normalized through
  `List.wrap/1` so a single struct or nil cannot reach `MapSet.new/2` (`:265-266`).
- Legacy `"2.0"` interface default replaced by the Version module: the default
  `supportedInterfaces` entry derives `protocol_version` from
  `AshA2A.Protocol.Version.protocol_version()` (`protocol/json.ex:318-321`), not a local
  literal; `"1.0"` is the single default in `protocol/version.ex:12,15`
  (`@supported_default ["0.3", "1.0"]` at `:16`). The prior literal is SESSION-sourced (the
  `protocol/` dir is untracked; no diff exists).

## 5. Stream artifact-id threading (coordinator)

One stable artifact id per stream, shared by the SSE chunk emitter and the `{:stream_done,
...}` fold (v1.0 chunk reassembly keys on artifactId).

- `protocol/agent/runtime.ex:71-88`: `wrap_stream/4` takes a pre-minted `artifact_id`
  (default `nil` kept for compatibility) and casts
  `{:stream_done, task_id, artifact_id, parts, outcome}` (`:88`).
- `protocol/agent.ex:646-653`: `maybe_wrap_stream/2` mints the id (`:649`), stamps it on the
  task metadata (`:650`, `:stream_artifact_id`), and passes it into `wrap_stream/4` (`:651`).
- `protocol/agent.ex:599-606`: the `stream_done` fold reuses the id when present (`:603-606`);
  nil falls back to a fresh `Artifact.new/1` (`:604`).
- `transport/plug.ex:365-378`: `stream_parts/4` reads `:stream_artifact_id` from task
  metadata and mints only as a fallback for paths that never stamped it (`:372-378`); chunk
  frames (`:391`) and the `lastChunk` drain (`:396-400`) share it.
- The `AshA2A.Transport.Runtime` mirror stamps the same way (`transport/runtime.ex:459-464`).

## 6. Open items at ledger time

Compile gate: `MIX_BUILD_ROOT=_build-x8 mix compile --warnings-as-errors` — exit 0,
`Compiling 731 files (.ex)`, clean for ash_a2a (warnings printed are sibling apps:
`ex4pm`, pre-existing).

Open rows from the conformance statement (`docs/reference/a2a-v1-conformance.md`,
rows 20-26), re-verified against the tree; "conf :" cites that file.

- Row 24 — mismatched `contextId` on continuation is accepted — OPEN (GAP).
  Conf `:55`. `continue_task/5` never inspects the supplied contextId
  (`protocol/agent/runtime.ex:46-58`).
- Row 25 — no server-generated `contextId` (`""` sentinel for life) — OPEN (GAP).
  Conf `:56`. `Task.new/1` leaves `context_id` nil by default
  (`protocol/task.ex:74-75`).
- Row 26 — no court drives a real task to `TASK_STATE_REJECTED` via
  `message/send` — OPEN (GAP). Conf `:57`. Only terminal-decode lists name
  `:rejected` (`test/ash_a2a_v1_conformance_test.exs:45`,
  `test/ash_a2a_v1_sse_replay_test.exs:203`). X3's lane did not land a
  REJECTED producer.
- Row 23 — final merged artifact id vs emitted chunk id — CODE FIXED,
  DOC/COURT STALE. The threading (section 5) landed, but court (c) still
  pins no id equality (`test/ash_a2a_v1_artifact_streaming_test.exs:252-263`),
  the file header still says the fold "does not yet reuse the emitted id"
  (`:64`), and conf row 23 is still PARTIAL (`:54`).
- Row 21 — in-flight cancel refused `-32002` (the inline-cancel SEC-02
  class) — OPEN (PARTIAL). Conf `:52`; the race-safety refusal stands, pinned.
- Row 20 — cancel idempotency: repeat cancel is a strict refusal —
  OPEN (PARTIAL). Conf `:51`.
- Row 22 — `tasks/list` accepts `historyLength` — OPEN (PARTIAL). Conf `:53`.
- Dead `stringify/1` clause in `transport/plug.ex` — OPEN (residue).
  `:144-145` unreachable behind `:140` (section 2.3).
- `preferredTransport` codec gap — OPEN. Card round-trip drops the member
  (`protocol/agent_card.ex:18-23`).
- Protocol-agent clause-grouping warning — FIXED (verified). The compile
  gate exits 0 (below); a grouping warning would fail `--warnings-as-errors`.

## 7. Post-M7 wave resolutions (waves 2/3)

Appended at ledger close (2026-10-04). Same evidence labels as the header:
OBSERVED = file:line in this tree; SESSION = coordinator testimony the tree
cannot contradict.

### 7.1 Ownership correction: `docs/explanation/pplan-seams.md` (P3)

- The file is P3's lane artifact (untracked: `?? docs/explanation/
  pplan-seams.md` in git status).
- RD4 caught the `PPlanEngine` ghost: the draft named a module that exists
  nowhere in the tree. The coordinator applied the real module name on
  P3's file: the durability seam now reads `AshPPlan.Reactor.Durable.Engine`
  (`pplan-seams.md:14`, wired to `AshA2A.Execution.PPlan` `@provider`).
- The real module exists: `deps/ash_pplan/lib/ash_pplan/reactor/durable/
  engine.ex:1`. A tree-wide grep for `PPlanEngine` over `lib/ test/ docs/`
  returns zero hits — the ghost is gone, not just renamed once.
- The doc carries its own staleness falsifier (`pplan-seams.md:64`): remove
  or rename the Engine surface and the doc declares itself stale.

### 7.2 Cross-lane fixes landed outside any lane contract

All OBSERVED in the tree. Recorded per the cross-lane unblock convention
(section 2); authority cited per fix.

#### Z19's three TCK fixes (`lib/ash_a2a/transport/plug.ex`)

Authority: the TCK compatibility run (`a2a-v1-conformance.md`, TCK section —
"All MUST-category infrastructure failures ... were fixed in-session in
`lib/ash_a2a/transport/plug.ex`").

- Version gate: `a2a-version` header parsed and validated against
  `supported_default` (`transport/plug.ex:183-186`); a rejected version
  answers the spec-mandated `-32009` with the rejected version echoed in
  the response header, §3.6/§3.6.2 (`:210-216`).
- `tasks/resubscribe` ownership: an unknown or foreign task answers
  `-32001` task_not_found (spec §3.16, TCK STREAM-SUB-004), never `-32004`;
  an owned task answers `-32004` unsupported_operation because this plug
  has no resubscribe stream to attach (`transport/plug.ex:362-376`).
- Agent-card caching headers (spec §8.6.1): `Cache-Control: max-age=60`,
  body-hash `ETag`, `Last-Modified` on the card response
  (`transport/plug.ex:161-163`, SHOULD/MAY comment at `:167-169`); SSE
  frames carry `cache-control: no-cache` (`:482`).

#### Coordinator's wrapper list clause (`lib/ash_a2a/a2a_transport/plug.ex:187-243`)

- Transport opts nest the agent under `:a2a` — reading `opts.agent` directly
  is a KeyError that escapes the `rescue` (only FunctionClauseError is
  caught), killing the connection with an empty body; the clause reads
  `opts.a2a.agent` (`:187-195`).
- Tasks encode through the codec (`wire_task/1` + `JSON.encode!`, `:197-201`)
  into the camelCase string-keyed envelope (`:209-213`).
- `rescue` falls back to the vendored delegate instead of an empty body
  (`:222-225`); `catch :exit` answers the typed `-32004`
  unsupported_operation instead of delegating into the vendored plug's own
  crash (observed `-32700` on this path) (`:226-233`).

#### Spec-mapping doc row flips (`docs/reference/a2a-spec-version-mapping.md`)

- Flipped to match the TCK authority: `SubscribeToTask` `-32004` → `-32001`
  (`:47`); the four push-config rows `-32003` → `-32001` (`:49-52`).
- Same file pins the §9.5 parity rule: a task owned by a different verified
  principal is `-32001`, same as a missing task (`:80`).

#### Coordinator's `client.ex` http_error fix

- §5.4/§3.3.2 ErrorInfo mapping (`protocol/client.ex:768-820`, documented at
  `:76-80`): a `google.rpc.ErrorInfo` detail names the failure as a typed
  atom; a bare status whose body carries no ErrorInfo maps to
  `{:error, {:http_error, status, body}}` instead of being lost
  (`:771`, `:788-791`); an unmapped live reason stays raw (`:810-812`).

### 7.3 `client.ex` double-assignment (W1+W9) — resolution closed

Section 1.1 recorded this as PARTIAL_ALIVE. Now closed: the sequential
landing is verified with both surfaces coexisting in one struct —
`defstruct` carries `transport: :jsonrpc` and `verify_card_signature: nil`
together (`client.ex:109`), the two option pops are independent
(`:132-133`), and the card-verify surface is intact (`:168`, `:210`,
`CardSigning.verify/2` doc at `:189-190`). Disjoint surfaces, no hunk
splicing. Standing: resolved; the next `_LANES.md` should list the file
single-owner so the conflict does not recur.

### 7.4 Coordinator commit on main: P5's self-hosting

- Commit `02745ef` "feat(sa2a): self-host marketplace packs via ggen.toml +
  generated projections" is on main: `ggen.toml` (54 lines), `ggen.lock`,
  `generated/ash/semantic_map.ttl` (27 lines), `generated/ash/
  semantic_map_a2a.ttl` (95 lines). Its falsifier is in the message: sync
  green twice, third run "unchanged: content identical", sha256
  byte-identical across runs.
- Contract gap (SESSION): P5's brief omitted the no-git clause, so P5 is
  the one lane that committed during the wave. Recorded, not reverted —
  the commit is a complete, falsified work product.

### 7.5 M-wave registry decisions

- Court statuses are run-derived, not hand-edited:
  `mix ash_a2a.v1_conformance_report`
  (`lib/mix/tasks/ash_a2a.v1_conformance_report.ex`) executes every pinned
  court as a real OS subprocess (`:189`), and a court file that no longer
  exists on disk becomes `verdict: "FAIL"` (`:81`) — a status cannot be
  hand-edited into PASS without the court actually passing.
- Wave-1 snapshot vs ledger close (section 6 rows re-checked against the
  statement): rows 20 (cancel idempotency), 23 (merged artifact id), 24
  (mismatched contextId), 25 (server-generated contextId), 26
  (REJECTED via wire) flipped to CONFORMANT; row 22 (`historyLength` on
  `tasks/list`) stays PARTIAL. No hand-edits survived: every flipped row
  cites an executed court in the statement.
- `EXPECTED_ACTIVE_PACKS` gate: zero hits in this tree (grep over lib/
  test/ priv/ scripts/, `_build` excluded) — recorded as a SESSION-sourced
  coordinator decision, pending falsifier flips. The tree's nearest
  counterpart is the marketplace pack gate set described in the P5 commit
  message (7 pack gates in closure).

### 7.6 Open items at ledger close

- Durable `tasks/list`: `list_tasks_for/3` reads in-memory agent state
  (`transport/runtime.ex:622-623` via `agent.ex:143-145`); a durable store
  delegation exists and is courted (`test/ash_a2a_v1_taskstore_durability_
  test.exs:5-9` — `AshA2A.Protocol.Agent.State` put/get delegation, EKV).
  Owner: next wave lane. Next step: make `list_tasks_for/3` paginate the
  configured store, not GenServer state.
- Mid-flight stream resume (#8; issue number SESSION): the base plug
  refuses an owned-task resubscribe with `-32004` — no stream to attach
  (`transport/plug.ex:368-374`); the owned transport has the replay
  machinery (`a2a_transport/plug.ex:159` → SSE resubscribe,
  `Last-Event-ID` aware). Owner: next wave lane. Next step: port SSE
  replay into the base plug or pin a GAP row in the statement.
- TCK grpc/http_json suites: skipped at run time because the served card
  declared the JSONRPC interface only (`a2a-v1-conformance.md` transport
  matrix — grpc 0/72, http_json 3/83); the card's default interface is
  JSONRPC-only (`protocol/json.ex:329`). Owner: next wave lane. Next
  step: declare GRPC/HTTPJSON interfaces and re-run the TCK per binding.
- Skill-level `security_requirements`: card-level only
  (`protocol/agent_card.ex:81-82,106-107`); the skill type (`:35`) and
  builder carry none. Owner: next wave lane. Next step: extend the skill
  type + codec with the per-skill member, IDL-fidelity court first.
- HTTPJSON agent route: the client speaks `:http_json`
  (`client.ex:97,132`) but no served HTTP+JSON binding route exists and
  the card advertises no HTTPJSON interface (`json.ex:329`). Owner: next
  wave lane. Next step: HTTP+JSON server route + HTTPJSON interface
  declaration + TCK http_json run.

## See Also

- `docs/jira/v26.9.28-kernel/_LANES.md` (lane-ledger convention this file follows)
- `docs/reference/a2a-v1-conformance.md` (PARTIAL/GAP rows cited in section 6)
- `CHANGELOG.md` `[26.10.3]` section (wire retarget summary)
- `~/.claude/rules/same-checkout-fanout.md`
