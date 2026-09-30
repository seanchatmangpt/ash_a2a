# QME-1 ecosystem reference

Canonical specification: `seanchatmangpt/chatman-ecosystem@88b276f71e2c8e606553942cb721bceb6836a87e`

This repository participates in QME-1 as **PreparedEffect, receipt and replay consequence protocol**.

The canonical QME-1 specification remains the sole normative owner. This repository MUST link, project, or derive from that subject rather than copy its normative laws. Local evidence does not create authority: Candidate != Truth != Authority != DO != Standing.

Local conformance is additive. A local profile MUST NOT weaken exact-subject binding, canonical ownership, authority/consequence separation, independent observation, non-actuating replay, negative-knowledge falsifiers, semantic-manufacture provenance, or MXinf fail-closed behavior.

## v26.9.30 exact-source and standing closure

The reference path now consumes the current AshR2RML exact-source semantic-evidence envelope directly. SA2A admits the nested immutable source identity, RDFC-1.0 canonicalization, graph digest, replay identity, producer provenance and replayable envelope digest while preserving `authority = NONE` and `consequence = EVIDENCE_ONLY`. PreparedEffect therefore binds the exact semantic source without reimplementing RDF semantics.

Capability release also has an additive standing-closed mode. `release_from_standing/2` resolves a durable exact-subject Chicago receipt through `AshA2A.StandingRef`; `freeze_standing/1` freezes only capabilities carrying a recomputable CONFORMANT technical-standing binding; and `:standing_strict` makes the advertised/executable closure fail closed when standing evidence is absent, downgraded, or internally inconsistent.

The boundaries remain distinct:

```text
TechnicalStanding != ExternalStanding != RuntimeAuthority
```

Technical standing is qualification evidence. It neither asserts institutional acceptance nor grants DO authority. Existing `:strict` deployments remain compatible; standing closure is opt-in until consumers deliberately select `:standing_strict`.
