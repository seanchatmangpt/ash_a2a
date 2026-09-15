# ERRC tracker — ash_a2a post-v26.9.14

Started 2026-09-15, scope: real gaps and tooling friction surfaced across this
session's work on `epoch/v26.9.15-semantic-subject` → `main` → v26.9.14 (published,
then republished with doc corrections). Source material: this session's own
`docs/jira/v26.9.14/RELEASE_RECEIPT.md` §8 disclosures, the earlier remote-eval
deferred list, and the live friction hit running `act` locally.

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
