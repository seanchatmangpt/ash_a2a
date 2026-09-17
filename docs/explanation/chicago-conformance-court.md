# Chicago Conformance Court

`AshA2A.Chicago` is the falsification-based conformance court for
RFC-SA2A-002 v26.9.16. It sits above the two layers `architecture.md`
describes (projection, and admission/receipts): where those layers are the
subject, the Chicago court is the independent process that tries to falsify
claims about that subject's real, executed behavior, rather than trusting a
green test suite to have already done so.

The full specification is `docs/rfc/RFC-SA2A-002-v26.9.16.md`. The
implementation entry point is `AshA2A.Chicago` (`lib/ash_a2a/chicago.ex`);
the command-line entry point is `mix ash_a2a.chicago`
(`lib/mix/tasks/ash_a2a.chicago.ex`, full option reference via
`mix help ash_a2a.chicago`).

## Why a court instead of a test suite

RFC-SA2A-002's conformance predicate is deliberately not "tests pass":

```text
Conformant(S) => ExactIdentity(S) ^ FalsifiersAttempted(S)
                ^ ForbiddenStandingAbsent(S)
                ^ RequiredConsequencesObserved(S) ^ IndependentEvidence(S)

PASS = AttemptObserved ^ ViolationDidNotAcquireStanding
```

A court has to name the exact subject it ran against (`Subject`), declare
falsifiers it will genuinely attempt (`Falsifier`), and prove the attempt was
observed and the violation never acquired standing -- corroborated by an
independent OCEL 2.0 process observer (`Observer`), not by the court's own
assertion. `Result` carries the verdict algebra; `Runner` fixes the
execution order (RFC S104); `StandingReceipt` is the per-run receipt
(RFC S115).

## Courts and gates

Courts live under `lib/ash_a2a/chicago/courts/`. `AshA2A.Chicago.courts/0`
discovers every compiled module implementing the `Court` behaviour and
orders them by gate, then id; `AshA2A.Chicago.courts_for/1` narrows that to
the courts applicable to a given profile (`AshA2A.Chicago.Profile`:
`core | logic | plan | do | strict`, cumulative per RFC S25).

The court set spans all twelve RFC-SA2A-002 gates -- Gate 1 (Exact Identity
Fenced) through Gate 12 (Zero Runtime Inference on KNOWN) -- plus a set of
admission-pipeline courts that are not gate-numbered: ShEx structural
falsifiers, SHACL semantic falsifiers, Safe Datalog, N3, SPARQL, canonical
graph identity, root manifest, semantic envelope, and extension negotiation,
among others.

## Mandatory corpus, benchmarks, mutation testing

- **Mandatory falsifier corpus** (RFC S98): `priv/sa2a/chicago_mandatory_corpus.json`
  lists the fourteen RFC-SA2A-001 counterexamples this court must be able to
  reproduce. `AshA2A.Chicago.Crown.mandatory_corpus_coverage/2` resolves
  each member against a real, currently-declared court falsifier id; an
  unresolved member is a reported gap, not a silent pass.
- **Benchmarks**: `AshA2A.Chicago.Courts.Benchmarks` and
  `mix ash_a2a.chicago.bench` write verifiable raw timing results and
  refuse a tampered result file.
- **Mutation testing**: `AshA2A.Chicago.Mutation.Catalog` and
  `mix ash_a2a.chicago.mutate` apply named mutants to the real
  implementation and require the `SA2A-MUTATION` court's falsifiers to kill
  each one for real. `AshA2A.Test.ChicagoSelfTest` (`CHI-SELFTEST`)
  qualifies the qualification machinery itself, against a court fixture
  that deliberately lies.

## The Crown

`AshA2A.Chicago.Crown` assembles the release-facing package on top of a
run: RFC S31 twelve-gate coverage, S98 mandatory-corpus coverage, S145
compliance matrix (RFC-SA2A-001 requirement -> court/falsifier -> evidence
-> result), S114 package completeness, and the Appendix C evidence
questions. `mix ash_a2a.chicago --crown` writes it to `crown.json` in the
run's evidence directory; the printed standing never exceeds the underlying
run's own `StandingReceipt` standing.

## Running it

```text
mix ash_a2a.chicago --profile core
mix ash_a2a.chicago --profile do --court SA2A-AUTH-017
mix ash_a2a.chicago --profile strict --crown
mix ash_a2a.chicago --list
```

Courts that need test-only fixtures run under `MIX_ENV=test`. See
`mix help ash_a2a.chicago` for the complete, current option reference.

## See Also

- `docs/rfc/RFC-SA2A-002-v26.9.16.md` -- the full specification
- `lib/ash_a2a/chicago.ex` -- `AshA2A.Chicago`, the module this document
  describes
- `lib/mix/tasks/ash_a2a.chicago.ex` -- the `mix ash_a2a.chicago` task
- `lib/ash_a2a/chicago/crown.ex` -- release-facing package assembly
- `priv/sa2a/chicago_mandatory_corpus.json` -- the S98 mandatory corpus
- `docs/explanation/architecture.md` -- the two layers this court qualifies
- `CHANGELOG.md` -- the Chicago court addition, under Unreleased
