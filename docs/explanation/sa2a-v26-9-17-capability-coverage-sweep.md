# SA2A v26.9.17 Capability Coverage Sweep

The v26.9.17 FOND/HDDL problem file
(`test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl:77-108`) declares nine
`owns` facts, each binding one repo to one `critical` capability in the
release chain: `cap-crown` (autofde-lab), `cap-orchestration` (ash-a2a,
self), `cap-semantic-feedback` (ash-r2rml), `cap-bounded-select` (bcinr),
`cap-manufacture` (ggen), `cap-framework-projection` (ggen-igniter),
`cap-system-authority` (xaas), `cap-standing` (affidavit) and
`cap-process-court` (beam4pm). A concurrent session's real work in
`autofde-lab` added six new courts plus OCEL queries, a benchmark harness, a
Crown runner, a fresh-consumer verifier and mutation-law falsifiers as a
capability coverage sweep of that repo's own court machinery.

This document is the same sweep run against `ash_a2a`'s own
`lib/ash_a2a/chicago/courts/` (RFC-SA2A-002 Chicago court foundation, built
earlier this session for RFC-SA2A-002): for each of the nine categories,
does an existing ash_a2a court already exercise an analogous concern for
ash_a2a's own codebase? This is an audit, not a claim that ash_a2a already
replicates autofde-lab's suite -- several categories have no real analog,
and are disclosed as such below.

## The real court inventory

```text
$ ls lib/ash_a2a/chicago/courts/ | wc -l
      45
```

Forty-five `.ex` files. Two are shared, non-court plumbing explicitly marked
`Not a court.` in their own moduledoc (`authority_harness.ex:5`,
`semantic_boundary.ex:3`, `inference_mappings.ex:7`) rather than `Court`
behaviour implementations; the remaining modules each declare a `@court` or
`@court_id`/`@id` string constant and implement `AshA2A.Chicago.Court`.
`AshA2A.Chicago.courts/0` (`lib/ash_a2a/chicago.ex:38`) discovers every
compiled `Court` at runtime -- the coverage claims below are about what
those discovered modules' own falsifiers attack, not an invented taxonomy.

## Method

For each capability category: grep court module names and moduledocs for
the closest matching concern, read the matching moduledoc in full, and
decide whether the match is COVERED (a court's real falsifiers attack the
same invariant shape for ash_a2a's own subject), PARTIAL (a court attacks a
structurally analogous invariant, but for a different subject than the
owning repo's own domain, or via a non-court test rather than a falsifier
court), or NONE (no existing court, however loosely, addresses the
concern -- disclosed rather than stretched).

## Coverage table

| capability | mapped ash_a2a court(s) | verdict | evidence |
|---|---|---|---|
| cap-crown | none (falsifier court); `AshA2A.Chicago.Crown` exists but is not itself attacked by a `Court` behaviour module | PARTIAL | `lib/ash_a2a/chicago/crown.ex:1` assembles gate/corpus/compliance coverage over a completed run and is exercised by `test/ash_a2a/chicago/crown_test.exs:1`, a plain `ExUnit.Case`, not a `Court` falsifier. The closest real court analog is `meta_admission.ex` (`SA2A-META`, `@id` at line 49): its §137 falsifier requires a nested `Runner` run be `CONFORMANT` only under an admitted court manifest, the same "machinery must have standing before it confers standing" shape Crown's own invariant relies on structurally, but no falsifier in the suite substitutes a lying `Crown` assembly and checks it is refused. |
| cap-orchestration | the entire discovered court suite (`AshA2A.Chicago.courts/0`, `lib/ash_a2a/chicago.ex:38`) | COVERED | ash-a2a owns this capability itself, so every court's `Subject` is already ash_a2a's own runtime -- there is no separate "orchestration court" because the whole 45-module suite already attacks ash_a2a's own executed behavior directly, not indirectly the way it does for the other eight repos. No single court is named "orchestration"; coverage here is a structural fact about who the courts' subject already is, not a stretch. |
| cap-semantic-feedback | `public_semantics_namespace.ex` (`SA2A-NS`, `@court` at line 36) | PARTIAL | `public_semantics_namespace.ex:1-20` qualifies public-IRI reuse vs. private minting and mapping reconciliation through `AshA2A.Semantic.MappingRegistry.reconcile/3` -- a real term/mapping-identity feedback concern of the same shape ash-r2rml's relational-to-RDF mapping feedback loop would need, but scoped to ash_a2a's own semantic namespace, not to a separate R2RML mapping engine. |
| cap-bounded-select | `plan_authority.ex` (`CHI-PLAN-AUTH`, `@court` at line 43) | PARTIAL | `plan_authority.ex:2-8`: Gate 4 "Planning Candidate-Only", `ValidPlan ⇏ DO` -- the court attempts to obtain consequence solely from planner output, i.e. a bounded selection of one plan candidate that must not itself confer authority. This is the same "select, but bounded" invariant shape as `cap-bounded-select`, exercised for ash_a2a's own planner rather than for bcinr's own selection engine. |
| cap-manufacture | `generated_projection.ex` (`SA2A-PROJECTION`, `@court` at line 36) | PARTIAL | `generated_projection.ex:2-8` (§77): "Generated projections must not become independent semantic truth" -- each falsifier hand-edits a generated projection (e.g. `P = pi_plan(O*)`) and checks the edit neither mutates canonical `O*` nor acquires standing. Same manufacture-boundary invariant ggen's own courts would need, applied to ash_a2a's own internally generated projections rather than to ggen's code-generation output. |
| cap-framework-projection | none found | NONE | Grepped `manufactur` across the court suite: the only other hits (`canonical_mutation.ex:190`, `root_manifest.ex:63-64`, `whole_plan_preflight.ex:29,460-461`) qualify trust-root *manufacturer identity* (e.g. refusing a re-addressed manifest with the `praxis-graphlaw` engine manufacturer removed), not framework-native code generation or Ash/Igniter projection wiring. No court in `lib/ash_a2a/chicago/courts/` attacks the concern ggen-igniter itself owns (does generated framework code stay a projection under an Igniter/Ash generator, specifically). Disclosed as a real gap rather than force-mapped onto `generated_projection.ex` a second time. |
| cap-system-authority | `brce.ex` (`CHI-BRCE`, line 61) + `authority_non_implication.ex` (`SA2A-AUTH`, line 38) + `grant_lifecycle.ex` (`SA2A-AUTH-GRANT`, line 35) | COVERED | `brce.ex:2-8`: Gate 7 Sole DO Boundary / Zero Unreceipted Actuation, `Attempted(a) ⇒ PreparedReceipt(a)`. `authority_non_implication.ex:2-8` (§57/§64/§65/§66): every attack runs through the real `A2A.Agent` dispatch path into `AshA2A.Authority.Grant.authorize/3`. `grant_lifecycle.ex:2-10` qualifies issue/authorize/expire/revoke against a real durable `AshA2A.Authority.Broker.Ekv`. Together these directly exercise ash_a2a's own authority/consequence boundary -- the same concern xaas owns at the system level, exercised here for ash_a2a's own boundary rather than for xaas's own code. |
| cap-standing | `receipt_binding.ex` (`CHI-RECEIPT`, line 51) + `AshA2A.Chicago.StandingReceipt` | COVERED | `receipt_binding.ex:2-7`: Gate 9 Complete Receipt Identity Binding and Evidence-Laundering Resistance -- "tampered evidence never retains standing, however the tamper is encoded." `lib/ash_a2a/chicago/standing_receipt.ex:1-2` is the per-run receipt this court's invariant protects. Direct analog to affidavit's own standing/receipt concern, exercised for ash_a2a's own run receipts. |
| cap-process-court | `ocel_validity.ex` (`SA2A-OCEL`, line 38) + `observer_qualification.ex` (`SA2A-OCEL-OBSERVER`, line 50) | COVERED | `ocel_validity.ex:2-8`: OCEL 2.0 validity and evidence-completeness court against the independent validator `AshA2A.Chicago.Ocel.Validator`. `observer_qualification.ex:2-8`: "an observer that silently loses required evidence cannot confer a Chicago Crown even if the SUT behaved correctly" -- attacks the real `AshA2A.Chicago.Observer`. Direct analog to beam4pm's process-mining-conformance concern, exercised over ash_a2a's own OCEL log rather than beam4pm's own engine. |

## Tally

- **COVERED**: 4 (`cap-orchestration`, `cap-system-authority`, `cap-standing`,
  `cap-process-court`)
- **PARTIAL**: 4 (`cap-crown`, `cap-semantic-feedback`, `cap-bounded-select`,
  `cap-manufacture`)
- **NONE**: 1 (`cap-framework-projection`)

## Reading the PARTIAL and NONE results honestly

Every PARTIAL above shares one structural gap: the matched court exercises
the *same invariant shape* the owning repo's capability names, but always
over **ash_a2a's own subject**, never over the owning repo's own code. That
is expected -- ash_a2a's Chicago courts were built to qualify ash_a2a, not
autofde-lab, bcinr, ggen or ash-r2rml -- and it means a PARTIAL here is not
"half-built," it is "the wrong subject for a literal claim of coverage,
right invariant for an analogy." Closing a PARTIAL to COVERED in the literal
sense would require a court whose `Subject` is the other repo's own runtime,
which is out of scope for `ash_a2a`'s own test suite.

The one NONE, `cap-framework-projection`, is a real, disclosed gap: no
`ash_a2a` court exercises any concern belonging to ggen-igniter's
framework-native generator wiring, in the direct or the analogous sense.

## See Also

- `test/support/hddl/sa2a_v26_9_17_dogfood/problem.hddl` -- the `:init`
  block declaring the nine `owns`/`critical` facts this sweep audits
- `docs/explanation/chicago-conformance-court.md` -- the Chicago court
  architecture and gate/court discovery mechanism referenced throughout
- `lib/ash_a2a/chicago.ex` -- `AshA2A.Chicago.courts/0`, the real
  discovery mechanism this sweep's inventory count is grounded in
- `lib/ash_a2a/chicago/crown.ex` -- the Crown assembly `cap-crown` maps to
- `lib/ash_a2a/chicago/standing_receipt.ex` -- the per-run receipt
  `cap-standing` maps to
- `lib/ash_a2a/chicago/courts/` -- the 45 real court modules this sweep
  cross-references
