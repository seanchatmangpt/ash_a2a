# ash_a2a ULTRACODE-50

## Operating premise

`ash_a2a` is already the completed machine-native A2A substrate. This is a steady-state maintenance, qualification, repair, learning, and release loop. Do not describe v26.9.15 architecture as future work. If an invariant is missing at exact head, classify it as drift/regression and repair the canonical source.

## Provider contract

Use ZAI `glm-5.3-flash` only for model reasoning. Maximum concurrency is 50. Do not invoke Claude/Claude Code/Anthropic or silently substitute another model. If ZAI is unavailable, emit `BLOCKED(provider_unavailable)` and continue deterministic repository-native courts.

Repeated correct reasoning must be retired into ontology, DSL, planner structure, generator, policy, verifier, fixture, or typed refusal.

## Canonical invariants

- `AshA2A.Info` is capability truth. AgentCard/docs/protocol surfaces are projections.
- `Human != Agent != Capability != Task != Command != Execution != Receipt != SemanticSubject != Projection`.
- `SemanticSubject = (graph_digest, projection_digest, manufacturer_digest)`. Changing any member changes replay/fingerprint identity. Identity grants no authority.
- Planning is: admitted semantics -> PlanningIR -> ZAI candidate -> HDDL/FOND -> formal verification -> canonical re-admission -> ExecutionPackage.
- Planner/model output is never permission.
- `SELECT != CONSTRUCT != DO`.
- `CommandBus` is the only later consequence-bearing DO path.
- DurableServer/FLAME,/topology/Reactor/AshStateMachine/AshOban are manifestations of admitted capability; provider availability is not authority.
- RuntimeReceipt/receipts are typed evidence. Do not infer ALIVE from declaration, compile, mocks, stale SHA, or neighboring CI.
- Machine Experience closes: `UNKNOWN -> semantics -> admitted structure -> deterministic machinery -> receipt/replay`.
- Generated surfaces are repaired through canonical source/generator, not hand edits.

## 50-agent allocation

Each agent works in an isolated worktree and begins with:

```bash
pwd
git remote -v
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git status --short
```

1-5: `AshA2A.Info`, DSL/resource/domain introspection, capability IDs, AgentCard projection.
6-10: CommandBus, authority, principal/agent/task identity, consequence/refusal/cancel/replay.
11-15: PlanningIR, ZAI routing, HDDL/FOND synthesis, solver verification, re-admission.
16-20: SemanticSubject, fingerprints, RuntimeReceipt, receipt integrity, replay, tamper/drift refusal.
21-25: DurableServer continuity, typed TaskID, FLAME, topology/presence, Reactor/state-machine/Oban integration.
26-30: A2A protocol, Plug/HTTP, multi-turn, cancellation, streaming/input-required, protocol compatibility.
31-35: Ash/Spark/Igniter/ggen manufacture, deterministic regeneration, compile-time architecture enforcement.
36-40: telemetry/OCEL, real local observation fixtures, external evidence boundaries.
41-45: Hex package, consumer fixtures, dependency closure, Diataxis/docs projections.
46-50: Chicago adversarial court, exact-head determinism, security/refusal, package dry-run evidence.

## Every 30-minute epoch

### ORIENT
Prove exact repo/ref/SHA. Read current project metadata, architecture verifier, relevant source/tests, manufacturing receipt, CI, package definition, and prior `.ultracode/state`receipts.

### DIAGNOSE
Prioritize: authority violation; semantic/replay identity violation; exact-head build/test/package breakage; nondeterminism/unreceipted consequence; runtime continuity; protocol compatibility; missing machine-experience closure; projection drift.

Never rerun an unchanged failure without a new falsifiable hypothesis.

### REPAIR
Use `reuse -> compose -> extend -> invent`. Prefer public standards and existing Ash/OTP/A2A/formal machinery. Change the smallest canonical surface that eliminates the failure class.

### CHICAGO QUALIFY
Run focused tests first, then exact-head:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix ash_a2a.verify_architecture
mix test
mix hex.build
```

Prefer real repository-native collaborators: real OTP processes, real local protocol pipeline/server, real DurableServer/EKVStore where admitted, real filesystem/package bytes. Mock-only evidence cannot qualify a real-provider boundary.

### LEARN
Convert novel success/failure into a verifier rule, refusal, semantic identity rule, deterministic fixture, planner constraint, generator, or consumer court whenever possible.

### RECEIPT
Append exact base/head, commands/exits, failure, hypothesis, changed canonical sources, regenerated projections, authority ceiling, verification, falsifiers, standing, and remaining UNKNOWN/BLOCKED/UNSUPPORTED/REFUSED to `.ultracode/state/`. Preserve failure history.

## Collision and authority

- isolated worktree per agent;
- no concurrent edits to the same canonical source;
- integrate only narrow verified diffs;
- failed merges are evidence; do not force;
- generated conflicts are fixed through canonical generation;
- do not push directly to `main`;
- this loop does not merge PRs, publish packages, create releases/tags, or deploy.

## Eight-hour final court

After 16 epochs, run one final 50-agent release audit and:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix ash_a2a.verify_architecture
mix test
mix hex.build
```

If `mix hex.publish` advertises `--dry-run`, run `mix hex.publish --dry-run`; otherwise emit `UNSUPPORTED(hex_publish_dry_run)` and do not publish.

The final court must inspect the built package contents and verify that only intended package files are present.

It must emit a release receipt containing:

- exact SHA;
- `Mix.Project.config()[:version]`;
- package artifact path and digest;
- dependency closure identity where available;
- formatter/compile/architecture/test/package results;
- dry-run publication result or typed `UNSUPPORTED`;
- unresolved blockers;
- publication command that would be authorized later;
- explicit `publication_executed: false`.

No tag, GitHub release, Hex publication, PR merge, or production deployment occurs in this loop.

## Success

The loop succeeds when the next cycle requires less discretionary intelligence:

`UNKNOWN -> KNOWN -> FORMALIZED -> GENERATED -> VERIFIED -> RECEIPTED -> REPLAYABLE`.
