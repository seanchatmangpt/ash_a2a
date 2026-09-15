# ERRC tracker — ash_a2a post-v26.9.14

Started 2026-09-15, scope: real gaps and tooling friction surfaced across this
session's work on `epoch/v26.9.15-semantic-subject` → `main` → v26.9.14 (published,
then republished with doc corrections). Source material: this session's own
`docs/jira/v26.9.14/RELEASE_RECEIPT.md` §8 disclosures, the earlier remote-eval
deferred list, and the live friction hit running `act` locally.

## Cycle 4 (2026-09-15) — board-persona feature completion + process-mining
(Dr. Wil van der Aalst) lens review + ERRC refactor
(workflow `w66f0froy`, batch 1 of the standing 1-hour autonomous loop,
cron `3630974d`, 9 agents)

Completed the board-persona-deliberation plan
(`/Users/sac/.claude/plans/ultracode-it-needs-to-tingly-book.md`): 2 remaining
generic archetypal personas (GrowthFocusedFounderLed, cited to Wasserman
2012 "The Founder's Dilemmas"; ActivistPressured, cited to Brav/Jiang/Partnoy/
Thomas 2008, *Journal of Finance*) plus the `Deliberation` fan-out module
(`Task.async_stream/3` across all 3 personas, real `%{approve_shaped, other,
errored}` count, no fabricated consensus) and Chicago-style tests. Then ran
4 real process-mining-lens review dimensions targeting ash_a2a's own
OCEL/BRCE-adjacent code, grounded in van der Aalst's published process-mining/
conformance-checking literature and a direct comparison against the real
canonical `Ex4pm.Evidence.BRCE.execute/5` implementation in `~/ex4pm` — this
closes the "is CommandBus reinventing BRCE" investigation flagged as
highest-priority after Cycle 3.

- [x] CREATE (executed): board-persona feature completed and merged (5 files,
      667 insertions) — independently re-verified by the orchestrating
      session before merge (not just the batch agent's self-report):
      `mix test` 345/0 (8 excluded), `mix ash_a2a.verify_architecture` 9/9,
      zero real mock matches.
- [x] CREATE (executed): `CommandBus.run/4`'s dispatch call now fails closed
      instead of crashing — an exception/throw/exit inside
      `dispatch_with_ocel_correlation/4` previously propagated uncaught
      through `run/4` into the calling `A2A.Agent` GenServer, killing it and
      leaving the pre-dispatch claim permanently stuck at `receipt: nil`.
      New `safe_dispatch/4` mirrors the exact rescue/catch pattern already
      used by `claim_receipt/3`/`commit_receipt/3` in the same file. +2 tests.
- [x] CREATE (executed): `SemanticProjection.ocel_event/1` now defaults
      `relationships` to `[]` instead of omitting the key entirely on the
      nil-dispatch-correlation branch. Additive, no behavior change on the
      branch that already set the key. +1 test.
- [x] CREATE (executed): moduledoc clarification in `CommandBus`/
      `ReceiptStore` — this codebase's "replay" is Stripe-style
      idempotency-key command dedup, not process-mining trace-replay/
      conformance-checking (cites Rozinat & van der Aalst 2008). Docs-only,
      no behavior change.
- Verified after all 4 CREATE fixes, on `main` (base `84302d4` → `f486f3e`,
  pushed, board-persona merge `08fa9bf` included): `mix format` clean,
  `mix compile --warnings-as-errors` clean, full suite `3 doctests, 9
  properties, 354 tests, 0 failures (8 excluded)` (+8 from the pre-cycle
  346 baseline), `mix ash_a2a.verify_architecture` 9/9, zero real mock
  matches. 4 worktrees (`loop1/*`) merged sequentially with real per-branch
  verification (one real, clean auto-merge conflict in `command_bus.ex`
  between the crash-guard and docstring-clarification branches, resolved
  by git itself — both touched non-overlapping regions), then removed as
  redundant once confirmed fully merged.

## Cycle 4 process-mining findings parked — needs explicit human sign-off

The CommandBus-vs-BRCE architectural question (flagged after Cycle 3) is now
answered with real evidence, not assumption:

- **CommandBus genuinely does more than BRCE in some respects** (compiled
  routing via `AshA2A.Info.skill/2`, three-way fail-closed consequence
  classification with no default-safe fallback for `:unknown`, a typed
  subject/capability/expiry-bound `Authority` struct) — confirmed real,
  intentional design, not a gap. No fix needed.
- **`AshA2A.Receipt` has no `hash`/`parent_hash` and no independent
  recompute-and-compare replay verification** — `Ex4pm.Evidence.Receipt`'s
  `Replay.verify/1` is genuine tamper-evidence (recompute + compare against
  a stored hash); `AshA2A.Receipt.replay/1` is idempotency-caching only, a
  structurally different property. `bounded_and_safe: false` — adding
  hash/parent_hash would change `Receipt`'s field contract and every
  `from_reply/4` call site plus any external wire consumer. Needs explicit
  human sign-off on the receipt schema change.
- **Emitted OCEL event shape uses ad hoc flat keys, not real OCEL 2.0's
  `ocel:`-prefixed wire vocabulary** — confirmed this is an intentional,
  disclosed design choice targeting beam4pm's specific ingest contract
  (`docs/jira/v26.9.11/ocel-v2-telemetry-forwarder.md`), not a bug, but the
  divergence from the actual OCEL 2.0 standard is real. `bounded_and_safe:
  false` — cross-repo (ash_a2a ↔ beam4pm) wire-contract decision. Options:
  dual emission (standard + beam4pm-specific) or getting beam4pm's router
  to translate; at minimum rename away from implying standard-OCEL-2.0
  conformance if the current contract is kept.
- No object catalog / event-type-attribute-schema catalog ever emitted; no
  process-discovery/conformance-checking step ever runs over accumulated
  receipts; `task_id` never reaches OCEL relationships/objects (only a flat
  attribute); per-lineage observation list grows unbounded, re-serialized
  in full into every replan prompt. All real, all architecture-level,
  parked without action this cycle.

## Cycle 3 (2026-09-15) — Zach Daniel / Chris McCord adversarial review + ERRC refactor
(workflow `wlnyxcjht`, 15 agents), part of the standing 1-hour autonomous
ERRC innovation loop (cron `3630974d`, personas: Ash/Spark idiom, Phoenix/OTP
idiom, process-mining/Dr. Wil van der Aalst lens for later cycles)

9 review dimensions (4 Ash/Spark-idiom, 4 Phoenix/OTP-idiom) produced 26
findings; ERRC-synthesized into 10 ELIMINATE (confirmed non-issues, see
below), 7 REDUCE (deferred, listed below), 0 RAISE, 0 CREATE, and 5
top-severity items selected for immediate bounded execution.

- [x] CREATE (executed): OCEL telemetry POST made async (`Task.Supervisor`
      offload in `lib/ash_a2a/telemetry/ocel_forwarder.ex` +
      `lib/ash_a2a/application.ex`) — a stalled/slow OCEL ingest endpoint
      previously blocked the single-mailbox `A2A.Agent` GenServer that also
      serves the inbound HTTP request. Additive, zero success-path behavior
      change. +1 test.
- [x] CREATE (executed): `AshA2A.ReceiptStore.Ekv.claim/2`/`commit/2` made
      atomic via EKV's own CAS (`if_vsn:`) instead of a racy
      read-then-write — the module's own moduledoc self-diagnosed this TOCTOU
      gap; without the fix two concurrent claims on one fresh `command_id`
      could both succeed, double-dispatching a consequence-bearing command.
      New test: 25 real `Task.async` racers, exactly one wins. This item's
      own refactor agent paused mid-task on an unrelated plan-mode interrupt
      (edits made, uncommitted); completed, independently re-verified, and
      committed by the orchestrating session per the standing "do not stop"
      directive. +1 test.
- [x] CREATE (executed): `CommandBus.run/4` now fails closed
      (`{:error, refusal(:receipt_store_unavailable)}`) instead of crashing
      the shared caller process when the backing receipt store is
      transiently unavailable (`ReceiptStore.Memory` GenServer killed, or
      `ReceiptStore.Ekv`'s `:persistent_term` config missing). Verified via
      falsifier: reverting the lib change made the new tests genuinely fail.
      +2 tests.
- [x] CREATE (executed): `Delivery.Oban.payload/1` now round-trips
      `Command.semantic_subject` — it was being dropped entirely, so
      `Command.fingerprint/1` (which folds the semantic-subject token into
      its hash) could not round-trip for continuation-flow commands
      delivered via Oban. Real Postgres/`oban_jobs` end-to-end test added.
      +2 tests.
- [x] CREATE (executed): `TaskLifecycle.admit/3`'s `action` argument no
      longer silently defaults to `nil` — the default routed to
      `AshStateMachine.possible_next_states/1` (any-action reachability, a
      materially weaker check) instead of the per-action legality check.
      Both real call sites already passed `action` explicitly, so this is
      behavior-preserving; it only removes a footgun. This item's refactor
      agent also paused on the same plan-mode interrupt; completed the same
      way as the EKV item above.
- Verified after all 5 CREATE fixes, on `main` (base `5cb3837` → `ea955f6`,
  pushed): `mix format` clean, `mix compile --warnings-as-errors` clean,
  full suite `3 doctests, 9 properties, 346 tests, 0 failures (7 excluded)`
  (+6 from the pre-cycle 340 baseline), `mix ash_a2a.verify_architecture`
  9/9, `grep -rn "Mox\|:meck\|Mock(" test/` zero real matches. 5 worktrees
  (`refactor/*`) merged sequentially with real per-branch verification,
  then removed as redundant once confirmed fully merged.
- [x] ELIMINATE (10 confirmed non-issues, no fix applied): `resource_dsl?/1`'s
      raw `Module.get_attribute(:spark_is)` reflection (correct idiom for
      its self-referential mid-compile position, not a duplication of
      `Spark.Dsl.is?/2`); `Authority.admits?/2` correctly not modeled as
      `Ash.Policy.Authorizer` (answers a structurally earlier question);
      `dispatcher.ex`'s direct `Changeset`/`Query`/`ActionInput` calls are
      the documented low-level API, not a framework-fighting shortcut;
      `AshA2A.Delivery.Oban`'s plain `Oban.Job.new/2` is AshOban's own
      doc-sanctioned escape hatch for ephemeral non-persisted structs; Req's
      default retry policy never fires for the POST `ocel_forwarder.ex`
      uses (`:safe_transient` is GET/HEAD-only, confirmed from Req source);
      cold-boot child-start ordering in `application.ex` has no race
      (OTP starts static children strictly in order); a proposed switch to
      `rest_for_one` supervision was rejected (would widen blast radius
      without fixing the real gap, which the async-OCEL/fail-closed items
      above already cover); `Vocabulary`'s RDF/SKOS/OWL-Time prefix table's
      3-entry overlap with vendored `ash_r2rml` has no clean mechanical
      extraction available; the 7-module hand-copied fingerprint-hashing
      routine is a real but purely cosmetic DRY violation, deprioritized;
      `TaskLifecycle.possible_next_states/2`'s latent nil-action
      arity-probing branch is confirmed unreachable with the pinned
      `ash_state_machine ~> 0.2`.

## Remaining REDUCE from Cycle 3 (deferred past the 5-fix cap this cycle)

- [ ] `AshA2A.Dsl`'s nested `argument` DSL entity is accepted and persisted
      but never consulted by the real capability-compilation pipeline
      (`lib/ash_a2a/dsl.ex`, `lib/ash_a2a/verify.ex`) — silent no-op.
      `bounded_and_safe: true`, ready to execute: add a `{:warn, ...}` to
      `AshA2A.Verify.verify/1` for any override with non-empty `arguments`.
- [ ] Semantic pipeline (`Compiler.compile_source/3`, `Compiler.replan/4`)
      emits zero telemetry, bypassing the repo's own `:telemetry.span` idiom
      and already-wired OCEL forwarder. `bounded_and_safe: true`, purely
      additive.
- [ ] `AshA2A.Agent` moduledoc's "one mailbox, not a worker pool" disclosure
      predates the semantic-compile feature's measured 170s+ latency —
      needs a doc update reflecting real observed behavior.
- [ ] Group adapter (`lib/ash_a2a/topology/group.ex`) omits monitor/demonitor,
      the only mechanism to observe a later conflict-resolution kill of a
      "completed" register/join receipt.
- [ ] Group adapter never threads `opts` through, silently forcing every call
      onto the default cluster.
- [ ] Group adapter's `available?/0` only confirms the module is compiled,
      not that a Group instance is running under the registry name in use —
      misconfiguration crashes instead of the adapter's own documented
      fail-closed error.
- [ ] Req's connect-phase timeout is never configured in `ocel_forwarder.ex`,
      so the effective worst-case block is ~30s+ despite the configured
      `ocel_ingest_timeout_ms` implying ~2s.

## Not auto-executed — needs explicit human sign-off (Cycle 3, carried from wlnyxcjht)

- Spark-Persister-based caching for `AshA2A.Info`'s capability index
  (`lib/ash_a2a/info.ex`) — fully recomputed via Ash introspection on every
  call, with real Spark/`AshJsonApi` precedent for precomputing it. Marked
  `bounded_and_safe: false` by the reviewing workflow: needs design sign-off
  on staleness/consistency across resource-vs-domain subject kinds before
  any caching is added. Parked, not executed, per this session's standing
  discipline that architecture-level items get parked with a stated reason,
  never unilaterally executed even under a "do not ask questions" directive.

## Cycle 2 (2026-09-15) — "make sure all possible chicago tests run"

Discovered real, unused `ZAI_API_KEY`/`GROQ_API_KEY`/`ANTHROPIC_API_KEY`
credentials already present in this environment -- meaning the 5
`@moduletag :external_api`-tagged test files (excluded from every default
`mix test` run this entire session, "(7 excluded)" in every reported run)
had never actually been exercised despite being fully runnable.

- [x] CREATE: ran the full suite with `--include external_api` for the
      first time this session. Found and fixed 2 real gaps (see
      `CHANGELOG.md`'s `[26.9.14]` "Fixed" entry for full detail):
      real cross-test rate-limit contention between the 50-way concurrency
      probe and the unseamed semantic-request/replan LLM calls (fixed by
      raising both the real `GenServer.call` timeout and the ExUnit test
      timeout on the affected assertions -- confirmed via a real
      before/after reproduction: 3 timeouts -&gt; 0, 412s real runtime);
      and the beam4pm-server-dependent OCEL conformance e2e test, proven
      to genuinely pass (1 test, 0 failures) once a real local `beam4pm`
      server was started for real.
- [x] Scoped out, correctly: `beam4pm`'s own separate
      `test/beam4pm_powl_conformance_e2e_test.exs` hit its own real,
      pre-existing build-artifact gap (`native/rust4pm-wasm` WASM binary
      not built) -- a different repository's own build concern, not
      ash_a2a's to fix.
- [x] A broader recurrence found and fixed the same way: the fully-converged
      run still surfaced one more real timeout in a *different*
      `:external_api` file (`ash_a2a_freedom_gym_zai_test.exs`) than the
      first reproduction had hit -- confirming the contention is
      non-deterministic (depends on real rate-limit recovery timing, not a
      fixed test ordering) and not confined to the 2 files first found.
      Audited all real, unseamed live-LLM-call sites across the
      `:external_api` set (5 files) and applied the same
      `@tag timeout: 180_000` + `timeout: 170_000` fix to all of them
      (`ash_a2a_llm_profiles_test.exs`, `ash_a2a_freedom_gym_llm_test.exs`,
      `ash_a2a_freedom_gym_zai_test.exs`, matching the pattern already
      established in `ash_a2a_agent_semantic_request_test.exs`/
      `ash_a2a_agent_semantic_replan_test.exs` and the pre-existing
      precedent in `ash_a2a_zai_concurrency_ocel_test.exs` itself), rather
      than continuing to patch tests one failure at a time as real network
      timing happened to expose them.
- [x] Final state, both modes verified real: default `mix test` unchanged
      (`3 doctests, 9 properties, 340 tests, 0 failures (7 excluded)`);
      `mix test --include external_api` (all 5 previously-always-excluded
      files plus the beam4pm-server-dependent e2e conformance test, run
      together in one process): `3 doctests, 9 properties, 347 tests, 0
      failures, 0 skipped`. Every real test this repository has, passing
      for real, at once.

## Cycle 1 (2026-09-15) — ERRC workflow run, 3 RAISE items executed

Ran via the `errc-cycle` skill (`~/.claude/workflows/errc-cycle.js`): categorized
6 items, independently re-verified 3 as `safeToVerify`, parked 3 needing explicit
sign-off. The user then explicitly resolved the parked `ash_oban` direction
("supposed to be for CRON etc, why dead? Fix") — executed immediately after.

- [x] ELIMINATE: `consequence: :observe` override struck from this tracker (was
      already independently confirmed not a defect — see `## Remaining ELIMINATE`
      below, now empty).
- [x] RAISE: `act` tooling friction — added `.actrc` (pins
      `catthehacker/ubuntu:act-latest` + `linux/amd64`, matching `ci.yml`'s real
      `ubuntu-latest`) and `bin/ci-local.sh` (picks whichever real Docker context
      is actually alive right now — the errc-cycle verification found the active
      `desktop-linux` context dead and `colima` live at that moment; by execution
      time both were live again, confirming the fix must detect at runtime, not
      hardcode one observation). Verified for real: `./bin/ci-local.sh --list`
      resolves the job with zero architecture warnings. **Partial only, disclosed
      in `bin/ci-local.sh`'s own comments**: a separate, dedicated validation run
      (8 real configurations: native arm64, `--container-architecture linux/amd64`
      under emulation, `-u root`, multiple runner-image tags) found that a full
      `act push -j test` cannot complete end to end on this Apple-Silicon host --
      every attempt failed inside the third-party `erlef/setup-beam@v1` action's
      own OTP/Elixir install (arm64 images miss `libcrypto.so.1.1`; amd64
      emulation hits an `erlexec` binary-format mismatch), before this repo's own
      `mix test` ever ran. This shim fixes the Docker-context/Postgres-port
      friction layer, not that deeper OTP-toolchain/image gap. Real hosted GitHub
      Actions on the same SHA remains the authoritative local-parity signal until
      an OpenSSL-1.1-capable runner image is found.
- [x] RAISE: `ash_oban` declared-but-unexercised — resolved by EXERCISING it (the
      user's explicit direction), not removing it. `test/support/scheduled_sweep_fixture.ex`
      + `test/ash_a2a/scheduled_sweep_qualification_test.exs` (3 real tests, real
      Postgres-backed `oban_jobs`, `AshOban.Test.schedule_and_run_triggers/2`, no
      mocks). Found and fixed a real integration gotcha along the way: the
      installed `ash_oban` version's scheduled-action worker only invokes via the
      generic-action path regardless of the DSL doc text saying "generic or
      create action" — documented in `CHANGELOG.md` and `RELEASE_RECEIPT.md`'s
      addendum so the next integrator doesn't rediscover it the hard way.
- [x] RAISE: ~100 (64 raw / 32 unique) ExDoc "hidden reference" warnings — the
      ash_a2a-owned subset (5 entities, 22 occurrences across 10 files) de-linked
      by dropping the trailing `/arity` from each backtick reference (no un-hiding,
      no prose-meaning change). Verified via a real before/after `mix docs` run:
      64 → 22 raw hidden-warning lines; the remaining 22 confirmed to be exactly
      the correctly-out-of-scope dependency/stdlib internals (`A2A.Agent.Runtime`,
      `DurableServer.Backends.EKVStore`, `A2A.Plug.Auth`, `AshR2RML.Resource.Verify`,
      `Mix.CLI`), not silently assumed to have dropped.

Verified after all 3 RAISE fixes: `mix format` clean, `mix compile
--warnings-as-errors` clean, full suite `3 doctests, 9 properties, 340 tests, 0
failures (7 excluded)`.

## Remaining ELIMINATE

(none remaining)

## Remaining REDUCE (needs scoping down before any action)

- [ ] DurableServer cross-node rehome unexercised (only real single-node kill+restart
      is proven) — a real multi-node fixture (two real BEAM nodes, like
      `distributed_node_loss_test.exs` already does for `Group`) is the right shape,
      but sizing/scheduling that is a separate decision from this cycle.

## Remaining RAISE

(none remaining this cycle)

## Remaining CREATE (new capital needed)

- [ ] Repo release hygiene: zero GitHub Releases published despite CHANGELOG
      reaching v26.9.14; no `ROADMAP.md`; empty repository topics.

## Not auto-executed — needs explicit user sign-off

- DurableServer multi-node rehome fixture — sizing/scheduling decision, not a
  same-cycle mechanical fix.
- Repo release hygiene (cut a GitHub Release, add `ROADMAP.md`, set topics) — a
  real publishing/visibility decision, not a mechanical fix.
