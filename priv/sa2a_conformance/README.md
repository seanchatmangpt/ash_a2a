# SA2A Conformance Corpus

The fixed, content-addressed semantic law package that two different runtimes
consume when earning **SA2A Portable Semantic Execution Conformance**
(RFC-SA2A-001 v26.9.16, sections S12, S15, S46, S61, S77).

Every expected value in this package is a **digest** (BLAKE3 of the canonical
form, as computed by the pinned engine) or a **typed refusal code**. No expected
value is a serialized RDF string, because representation differences between two
runtimes would contaminate the semantic claim being made.

Every digest and every status in `MANIFEST.json` and in the `*.expected.json`
sidecars was **measured** by running the real pinned wasm over these real files,
not authored by hand.

## What the qualification claims

```
Runtime_A != Runtime_B,  WASM_A = WASM_B,  O*_input,A = O*_input,B
  =>  Admission_A = Admission_B,  O*_output,A = O*_output,B,  Refusal_A = Refusal_B
```

...over **this finite suite**. It does not establish universal semantic
equivalence, production ALIVE, security completeness, or cross-*implementation*
equivalence.

## Package layout

| Path | Role |
| --- | --- |
| `base.ttl` | Baseline subject graph: one blank node, datatyped and language-tagged literals |
| `event.ttl` | Event delta, the 2nd argument of `run_hooks/2` |
| `profile.ttl` | Semantic profile, the 2nd argument of `validate_all/5` |
| `shapes.shacl.ttl` | SHACL shapes, both `sh:Violation` and `sh:Warning` severity |
| `shapes.violations.shacl.ttl` | Same shapes, `sh:Violation` constraints only (S15 partition) |
| `shapes.warnings.shacl.ttl` | Same shapes, `sh:Warning` constraints only (S15 partition) |
| `schema.shex` | ShEx schema in **ShExJ** (see "Measured boundary facts") |
| `shape_map.json` | ShEx shape map, the 5th argument of `validate_all/5` |
| `rules/denials.n3` | Graph-global falsifier: an N3 denial rule |
| `hooks/admitted_hooks.ttl` | The admitted GraphLaw knowledge hooks |
| `positive/`, `negative/` | Vectors, each with a `.expected.json` sidecar |
| `MANIFEST.json` | Real sha256 + blake3 of every file, plus the engine identity |

The **law graph** a runtime validates is the subject graph concatenated with
`rules/denials.n3` and `hooks/admitted_hooks.ttl`, joined by `\n`. The S12
identity vectors hash the **subject graph alone**. Both digests are recorded per
vector.

## Vectors

| Vector | Class | SA2A admission | Conformance on the pinned engine |
| --- | --- | --- | --- |
| `base.ttl` | positive baseline | ADMITTED | HOLDS |
| `positive/base_bnode_relabelled.ttl` | canonicalization isomorphism | ADMITTED | **FAILING** (see below) |
| `negative/one_triple_changed.ttl` | canonicalization distinctness | ADMITTED | HOLDS |
| `negative/shex_structure.ttl` | invalid structure (ShEx) | REFUSED `sa2a_shex_nonconformant` | HOLDS |
| `negative/shacl_violation.ttl` | SHACL violation | REFUSED `sa2a_shacl_violation` | HOLDS |
| `negative/shacl_warning_only.ttl` | warning-only, must still admit | ADMITTED | HOLDS |
| `negative/shacl_violation_and_warning.ttl` | violation over warning | REFUSED `sa2a_shacl_violation` | HOLDS |
| `negative/falsifier_positive.ttl` | graph-global falsifier | REFUSED `sa2a_denial_fired` | HOLDS |
| `negative/unadmitted_predicate.ttl` | hallucinated predicate | REFUSED `sa2a_unadmitted_predicate` | HOLDS |
| `negative/malformed.ttl` | malformed Turtle | REFUSED `sa2a_malformed_graph` | HOST GATE REQUIRED |

Each vector isolates a **single** dialect wherever the law allows it, so a
failure names one cause rather than a set.

## Measured boundary facts

These were established by really running the pinned wasm, not read off
documentation. `MANIFEST.json`'s `deferred` array carries the full text.

1. **Blank node relabelling is not canonical on the pinned engine.** Bisected:
   IRI prefix renaming, statement reordering, language tags and datatype-prefix
   renaming are all canonical; blank node relabelling alone is not.
   `graph_hash_core` hashes `TripleStore::content_to_string()`, a sorted N-Quads
   serialization that carries blank node labels through verbatim — it is not
   RDFC-1.0 blank node canonicalization. `positive/base_bnode_relabelled.ttl` is
   the falsifier for this and it currently **fires**.
2. **SHACL result severity is not exposed by the pinned wasm.** RFC S15 is
   nonetheless decided without it, by running `validate_all/5` twice over the
   severity-partitioned shape graphs and comparing the two SHACL statuses:
   `violations REFUSED` ⇒ REFUSE; `violations ADMITTED ∧ full REFUSED` ⇒ ADMIT
   (warning-only); both ADMITTED ⇒ ADMIT.
3. **Malformed Turtle is not refused by the engine.** Unparseable input degrades
   to a partial or empty graph with a real digest, never to `{"error": ...}`. A
   SA2A runtime must own a syntactic gate ahead of the engine boundary.
4. **Graph-declared hooks never register through `run_hooks/2`** on this build,
   including a minimal hook pack copied verbatim from a passing engine test. Hook
   *firing* is therefore not exercisable here; the pack is pinned and digested so
   it becomes a live falsifier the moment a build that registers it lands.
5. **The profile graph derives nothing.** `validate_all/5` hashes `profile.ttl`
   and uses its non-emptiness only to gate OWL RL on the base store; it never
   merges the profile's axioms into that store. No vector depends on a
   profile-derived entailment.
6. **The ShEx argument is ShExJ, not ShExC.** The wasm reaches
   `TripleStore::validate_shex/2` (the JSON path); `validate_shex_c/2` (compact
   syntax, an 80/20 subset parser) is a different entry point `validate_all/5`
   does not call.

## Loading it

`AshA2A.SA2A.Corpus.load!/0` reads this directory, re-computes the SHA-256 of
every manifested file, and raises if any byte drifted — the package is
content-addressed, so a silently edited fixture is a load-time failure rather
than a mysteriously changed test result.

## See Also

- `lib/ash_a2a/sa2a/corpus.ex` — the loader and its fail-closed digest gate
- `test/ash_a2a_sa2a_corpus_test.exs` — real tests over these real files
