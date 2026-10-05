# Migrate from legacy to strict behavior

This guide lists the seven behavior changes already present in `ash_a2a` on
`main` (v26.9.29 line) that can break a host written against the pre-v26.9.26
defaults, what each breaks, and the exact fix. Every default named here is
checked against the code by `test/ash_a2a/docs_truth_test.exs` where the key
is one of `:actuation_dedup`, `:capability_release_mode`, `:authority_policy`;
the others are stated from the cited source lines.

## Contents

1. Strict actuation dedup is the default
2. `resolved_skill` is verified against the compiled index
3. Receipt outbox seal and anchor durability
4. Continuation scoping
5. Strict observe classification (opt-in)
6. Pre-DO authority revalidation
7. Toolchain pin and mint upgrade
8. Verification checklist
9. See Also

## 1. Strict actuation dedup is the default

- **Change**: `AshA2A.CommandBus.actuation_dedup_mode/1` now defaults to
  `:strict` (was `:declared`). For every `:change` and `:external_do` command
  the effect claim is enforced on the derived effect digest, with or without an
  idempotency token.
- **What breaks**: two distinct `command_id`s that name the same effect (same
  resource, action, and input) no longer both actuate; the second is answered
  from the first claimant's committed receipt or refused. Tests that re-run the
  same create with the same input under fresh command ids now see a replay, not
  a second row. A receipt store that does not implement `claim_actuation/3`
  gets no actuation dedup (command-id claiming only).
- **Fix**: give genuinely distinct effects distinct inputs (for example a real
  business key). To keep the old behavior for a bounded window, set
  `config :ash_a2a, :actuation_dedup, :declared` (or `:off`); receipts then
  record `intended_effect.actuation_dedup_compat` as `:declared_legacy` or
  `:off_legacy`. Per call: `CommandBus.run(cmd, msg, res, actuation_dedup: :declared)`.

## 2. `resolved_skill` is verified against the compiled index

- **Change**: `AshA2A.Dispatcher` no longer trusts a caller-supplied
  `:resolved_skill` option. It must be structurally identical to the skill in
  the compiled index (`lib/ash_a2a/dispatcher.ex`, `verify_resolved_skill/2`).
- **What breaks**: a host or test that hand-builds an `%AshA2A.Skill{}` (for
  example with a different `consequence:` to bypass admission) and passes it as
  `resolved_skill:` is refused with reason `:resolved_skill_not_in_index`.
  A missing or non-`%Skill{}` value is refused the same way.
- **Fix**: stop passing `:resolved_skill`; let the dispatcher resolve from the
  DSL (`AshA2A.Info.skill/2`). To change a skill's class, change the DSL
  declaration and recompile.

## 3. Receipt outbox seal and anchor durability

- **Change**: outbox entries are sealed (HMAC-SHA256 over the term bytes) and
  the entry is the at-most-once anchor persisted before DO. Writes are fsynced
  and the directory is fsynced after rename. `AshA2A.ReceiptStore.boot_check/1`
  refuses a durable receipt store paired with a tmp-dir outbox.
- **What breaks**: (a) boot refuses with a durable store (`ReceiptStore.Ekv`)
  and the default `:receipt_outbox_dir` (`System.tmp_dir!()/ash_a2a_receipt_outbox`);
  (b) entries written with no key are marked untagged and a runtime that later
  has a key refuses them; (c) a torn or unreadable entry blocks reclaim of its
  own command.
- **Fix**: set `:receipt_outbox_dir` to persistent storage and set
  `:receipt_binding_key` (at least 32 random bytes, identical on every node;
  `:receipt_outbox_key` is also honored). Drain or delete pre-key entries before
  turning the key on. Dev/test with the memory store needs no change.

## 4. Continuation scoping

- **Change**: tasks are owned by the verified principal that created them.
  A continuation (`:input_required` follow-up) always runs under the current
  call's verified auth, and prior-turn `Data` arguments are carried only when
  the continuation carries the matching `:continuation_fingerprint` metadata.
- **What breaks**: a different principal continuing a task gets
  `{:error, :not_found}`; a continuation without the fingerprint no longer
  jumps straight to a fresh compile with the prior arguments; clients that
  relied on unauthenticated continuation fail closed
  (`:require_authenticated_caller` defaults to `true`).
- **Fix**: continue tasks as the creating principal, echo the fingerprint the
  agent returned, and serve HTTP through `AshA2A.Transport.Plug` (owner-scoped
  `tasks/*`), not the raw `AshA2A.Protocol.Plug`. Public skills are opt-in via
  `public_skills: [...]`.

## 5. Strict observe classification (opt-in)

- **Change**: `:strict_observe_generic_actions` gates generic `:action` skills
  that have no explicit `consequence:`. It is **opt-in** (default `false`), so
  nothing breaks until you enable it.
- **What breaks when enabled**: a generic action skill with no declared
  consequence is refused `:consequence_unclassified` unless it is public or
  listed in `observe_generic_actions`.
- **Fix**: declare the class in the DSL, for example
  `skill(:ping, :ping, consequence: :observe)`, or list the skill in
  `observe_generic_actions`. Enable with
  `config :ash_a2a, :strict_observe_generic_actions, true` or per agent.

## 6. Pre-DO authority revalidation

- **Change**: immediately before DO (after the anchor is persisted and the
  claim confirmed) `CommandBus` re-checks authority against the authoritative
  broker and consults the kill switch again. Either failing means no DO, the
  anchor and actuation claim are released, and a refusal receipt is closed.
- **What breaks**: a grant revoked or expired between admission and actuation
  now refuses with `:authority_revoked` or `:authority_expired`; a broker that
  cannot be consulted refuses `:authority_revalidation_unavailable` (fail
  closed); an authority whose `constraints` do not match the command refuses
  `:authority_constraint_mismatch`. Child VMs or tests that carry an
  authority but start no broker now refuse instead of actuating.
- **Fix**: run the broker your grants came from (`Broker.InMemory` for tests,
  `Broker.Ekv` in production) and configure it as `:authority_broker`, or pass
  `authority_broker: {Module, opts}` per call. In tests use
  `AshA2A.Test.Governed` (see [test governed actions](test-governed-actions.md)).
  Note `:authority_policy` defaults to `:broker`; `:transport_verified_grants_capability`
  violates RFC-SA2A-001 S29 and is a migration-window escape only.

## 7. Toolchain pin and mint upgrade

- **Change**: `.tool-versions` pins `elixir 1.20.4-otp-29` and `erlang 29.1.1`;
  `mint` moved 1.10.1 to 1.11.0 (Hex advisories); `scripts/toolchain.sh`
  puts the pinned toolchain first on `PATH`.
- **What breaks**: a shell that resolves a different Elixir/OTP builds against
  other versions than CI; code that compiled with warnings on older Elixir now
  fails `--warnings-as-errors` on 1.20; `mix.lock` drift fails the CI
  supply-chain gate.
- **Fix**: `source scripts/toolchain.sh` (must be sourced, not executed), then
  `mix deps.get` and rebuild. Hosts pinning `mint` below 1.11 must upgrade.

## 8. Verification checklist

Run against your host after migrating:

1. `mix compile --warnings-as-errors` on the pinned toolchain.
2. Dispatch one `:change` skill twice with the same input under two command ids:
   the second must be a replay (item 1).
3. Revoke a grant and dispatch: expect `:authority_revoked` (item 6).
4. Boot with the production config: `boot_check/1` must not refuse (item 3).

## 9. See Also

- [Configuration reference](../reference/configuration.md)
- [Verify authority on async paths](verify-authority-on-async-paths.md)
- [Test governed actions](test-governed-actions.md)
- `docs/rfc/RFC-SA2A-004-v26.9.28.md` (normative) and `RFC-SA2A-007-errata-v26.9.28.md`
