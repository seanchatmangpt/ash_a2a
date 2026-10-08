# A-DOC — the a2a side of v26.10.2

DOCS-lane receipt for the a2a side of the v26.10.2 wave. Subject: `main`
@ `ccdb634` + this doc. Companion lanes: config/courts own lib/test;
this lane owns `CHANGELOG.md`, `docs/`, `README.md` prose only
(no code, no mix runs, no git writes).

## Courts (C7)

`619bbb3` kills the three authority/envelope courts that passed vacuously:

- SA2A-AUTH-022/023/024 — subject/capability binding + expiry through the
  real Grant -> CommandBus path (the court starts a court-owned InMemory
  broker and mints through the real Grant API, not hand-minted authority).
- SA2A-AUTH-GRANT-012/013 — grant-layer binding + past-`expires_at` refusal.
- CHI-ADM-014 — the semantic envelope's standing guard now executes on the
  court path: a payload declaring its own standing is refused
  `:standing_self_declared` (previously 0 calls on that path).

Mutation run: 14 killed / 1 unknown (was 3 survived + 2 unknown); the
mutation manifest is re-pinned in the same commit.

## Audit (D6)

`0bdc6b7` migrates the 2 incidental Memory receipt stores to real on-disk
EKV (with a `receipt.standing == :durable` post-condition so the swap is
falsifiable) and lands the census: 46 non-chicago Memory consumers, the
rest lawfully classified by the store-as-subject law.
`LEGACY-COMPAT-AUDIT.md` (this directory) states the retirement criterion:
`:legacy_compat` is deprecable — zero in-repo consumers boot under it and
no documented host path recommends it.

## Witness — skipped, named

The HILT behavioral witness is ggen-side; the invariant it witnesses
(graph-digest checkpointing in `AshA2A.Hilt.WorkOrder` + `CommandBus`
admission, refusing `:stale_graph_identity`) is ours and was already
released in 26.9.31 (`6abdb9f`). Not re-documented as new.

## Doc-truth pass

- No live doc claims `CommandBus` lacks the work-order binding;
  `docs/reference/index.md` already states it accurately. The only
  `Authority.admits?/2` "unguarded" statements are point-in-time audit rows
  inside the dated `docs/rfc/RFC-SA2A-003-v26.9.28.md` evidence appendix
  (its "B4"/evidence-table rows predate the constraint-binding and
  court-strengthening state; the RFC is a versioned snapshot and was left
  in place, per the repo's dated-snapshot convention).
- Strict-profile closure requirement stated precisely:
  `docs/reference/configuration.md`'s `:capability_release_closure` row now
  says the gate reads closure from call opts then global env, so a global
  `:strict` mode with no global closure refuses
  `:capability_release_closure_missing` at skill-index expansion
  (`AshA2A.Info` -> `filter_skills/2`), before any dispatch.
- `:security_profile` row cites the `:legacy_compat` retirement criterion.
- CHANGELOG: post-26.10.2-section capabilities appended under [Unreleased];
  the [26.10.2] RD1 row corrected 22 -> 36 execution oracles (the release
  was built after the RD1-shrink commit `7c13f1e`, which raised the count;
  `docs/jira/v26.10.2/ERRC_TRACKER.md` cycle 2 is the receipt).
- README gained the HILT work-order binding plane bullet (was missing from
  the feature list; `AshA2A.Hilt.WorkOrder` was documented in the module
  index but not the README list).

## See Also

- `ARD.md` / `PRD.md` / `ERRC_TRACKER.md` — the ERRC frame for this wave
- `LEGACY-COMPAT-AUDIT.md` — the D6 census and retirement criterion
- `CHANGELOG.md` — [Unreleased] entries with the capability SHAs
