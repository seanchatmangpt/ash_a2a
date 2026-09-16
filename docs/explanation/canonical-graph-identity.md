# Canonical Graph Identity (RFC S12)

v26.9.16. This document corrects a false claim that reached three separate SA2A branches,
and records the measurements that settle it.

Three branches described the praxis-graphlaw wasm `graph_hash` export as RDFC-1.0 or as
S12-conformant. It is neither. This document states precisely what that export does
guarantee, what it does not, why real RDFC-1.0 nevertheless already exists in
praxis-graphlaw (just not at the wasm boundary), and why `ash_a2a` therefore takes its S12
canonical graph identity from RDF.ex in-BEAM.

The authoritative primitive is `AshA2A.Semantic.CanonicalGraph`. Nothing else in this
repository should compute a canonical graph identity. The other digests on `main` are
labelled engine or term digests, not S12 identities; see "Relation to the other digests"
below.

## Quick reference

| Question | Answer |
| --- | --- |
| Which module owns S12? | `AshA2A.Semantic.CanonicalGraph` |
| Algorithm | RDFC-1.0 (W3C RDF Dataset Canonicalization 1.0) |
| Hash function | SHA-256 over code-point-sorted N-Quads, lowercase hex |
| Pinnable identity string | `RDFC-1.0/SHA-256/n-quads-sorted` |
| Implementation | `:rdf` (RDF.ex) 3.0.1, `RDF.Graph.canonical_hash/1` |
| Unparseable input | typed `{:error, {:parse_error, _}}` -- never a digest |
| Non-UTF-8 input | typed `{:error, {:invalid_encoding, offset}}` -- refused pre-parse |
| Is graphlaw `graph_hash` S12? | **No.** See below. |
| What graphlaw keeps | S14 ShEx, S15 SHACL, S16 Datalog, S17 N3, S18 SPARQL |

## What the graphlaw wasm export actually guarantees

Measured against the vendored law package, `praxis-graphlaw v26.7.5`
(sha256 `187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28`,
3,249,361 bytes), executed for real through the dependency-free node host.

`graph_hash` **does** hold these two properties:

- **prefix relabeling invariance** -- renaming `ex:` to `zz:` does not move the digest;
- **triple reordering invariance** -- permuting the statements does not move the digest.

It computes a BLAKE3 digest over its own sorted serialization. Those two invariances are
real, useful, and were correctly observed. They are not sufficient for RDFC-1.0.

```text
base.ttl        9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
reordered.ttl   9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d   (equal)
mutated.ttl     610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66   (differs)
```

## What it does not guarantee

### 1. It is not invariant under blank-node relabeling

RDFC-1.0 exists almost entirely to solve this problem: blank-node labels are arbitrary
syntax, so two documents that differ only in those labels denote the same graph and must
receive the same identity. `graph_hash` gives them different digests.

```turtle
@prefix ex: <http://example.org/> .
ex:a ex:p _:b1 .
_:b1 ex:p ex:c .
```

```turtle
@prefix ex: <http://example.org/> .
ex:a ex:p _:zzz9 .
_:zzz9 ex:p ex:c .
```

```text
graphlaw graph_hash
  _:b1    98d6f0bb8000170baa790b30dc641ce0bd49ca82f7f9c0ce45452c2994e2820e
  _:zzz9  fa6b931d903050d2837bb557482f1669d8767ad12b1c340e68192a85de873215
```

The same pair under real RDFC-1.0 collapses to one identity, which is the correct answer:

```text
RDF.ex canonical_hash
  both    3c2f833bf34d489b97894abd575e4a8ac8d6b89564ee074ed45492402f278e5c
```

### 2. On unparseable input it returns the empty-graph digest instead of an error

This is the more dangerous of the two. A garbage document and an empty document are
indistinguishable in a receipt, so a receipt can record a real, well-formed-looking digest
for input that was never a graph at all.

```text
graph_hash("@@@ not turtle")
  af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
graph_hash("")
  af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
BLAKE3("")
  af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262
```

All three are the same value. RDF.ex fails closed on the identical input:

```text
RDF.Turtle.read_string("@@@ not turtle")
  => {:error, "Turtle scanner error on line 1: {:illegal, ~c\"@@\"}"}
RDF.Graph.canonical_hash of the empty graph
  => e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855   (= SHA-256 of "")
```

`AshA2A.Semantic.CanonicalGraph.canonical_digest/1` propagates the parse error verbatim as
`{:error, {:parse_error, message}}` and never returns a digest for input it could not parse.

### 3. It marshals its argument as a Rust `&str`, so non-UTF-8 input is not a parse failure

The wasm export takes a `&str`. As first written on `feat/graphlaw-wasmex-bridge-v26.9.16`,
its in-BEAM Wasmtime host (then `AshA2A.GraphLaw.Wasm`, merged to `main` as
`AshA2A.GraphLaw.WasmexHost`) guarded `graph_hash/3` with `is_binary/1` only. A single `0xFF`
byte is therefore not a document the engine rejects but a marshalling failure: the verifier
measured the engine committing 2,148,270,080 bytes and permanently poisoning the instance.

`AshA2A.Semantic.CanonicalGraph.ensure_utf8/1` is the guard, exposed publicly precisely so
that every Elixir caller of a wasm string export can run it first. See
"The wasm bridge UTF-8 guard (applied at merge)" below.

## praxis-graphlaw does contain real RDFC-1.0 -- it just is not exported

This is the part worth stating plainly, because "graphlaw cannot do RDFC-1.0" would itself
be a false claim. praxis-graphlaw contains a real RDFC-1.0 implementation at
`chatman/engine.rs:1176`, via `oxrdf`'s `Rdfc10`. It is not reachable from the wasm export
surface: the exports are `blake3_hex`, `graph_hash`, `graphlaw_version`, `init_panic_hook`,
`run_hooks` and `validate_all`, and `graph_hash` is not wired to `Rdfc10`.

So the correct statement is a capability-boundary statement, not a capability statement:
the algorithm exists in the Rust engine, and the wasm law package this repository vendors
does not expose it. Exporting it later is a real, available option; until then, S12 identity
is not something this repository can obtain from the wasm boundary.

## What ash_a2a does instead

RDF.ex 3.0.1 is already compiled into this repository's `_build`, transitively via
`:ash_r2rml` (`deps/ash_r2rml/mix.exs:122` declares `{:rdf, "~> 3.0"}` with no `:only`), so
adopting it costs **zero new dependencies** -- `mix deps.get` resolves with `mix.lock`
unchanged. `mix.exs` now declares it directly anyway, for exactly the reason the
`:stream_data` comment already in that file gives: `lib/` code depends on it for real, and a
real dependency should be declared rather than inherited from an incidental transitive pin
that an upstream package could drop or relax.

The scope is deliberately narrow. **RDF.ex is used here for canonicalization and
serialization only.** `:sparql`, `:json_ld` and `:shex` are not added and must not be. All
graph-shaped validation and reasoning stays in GraphLaw, which keeps S14 ShEx, S15 SHACL,
S16 Datalog, S17 N3 and S18 SPARQL -- where nothing else in reach comes close.

The algorithm, stated precisely because the Root Manifest pins it:

1. Parse as RDF 1.1 Turtle (`RDF.Turtle.read_string/1`); a parse failure is a typed error.
2. Canonicalize with RDFC-1.0 (`RDF.Canonicalization`).
3. Serialize to N-Quads sorted by Unicode code point order
   (`RDF.NQuads.write_string!(sort: true)`).
4. SHA-256 that serialization, lowercase hex.

RDFC-1.0 also uses SHA-256 internally for its blank-node first-degree and n-degree quad
hashes. Both that internal use and the step-4 digest hash are pinned to their defaults and
are not exposed as call-site options: an S12 identity that can be reparameterized per call
is not an identity.

## The three-way agreement result

The experiment, for a Turtle document `T`:

```text
A = graphlaw.graph_hash(T)
B = graphlaw.graph_hash(CanonicalGraph.canonical_nquads(T))
```

If `A == B`, the two engines agree on canonical form for `T`: handing graphlaw the RDFC-1.0
canonical serialization instead of the original concrete syntax does not move its digest.

**Blank-node-free graphs: the engines agree.**

```text
A = graphlaw(base.ttl)
  9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
B = graphlaw(RDFC-1.0 N-Quads of base)
  9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
```

**Graphs containing blank nodes: the engines diverge, and the divergence is the useful
result.**

```text
A = graphlaw(_:b1   variant)
  98d6f0bb8000170baa790b30dc641ce0bd49ca82f7f9c0ce45452c2994e2820e
A = graphlaw(_:zzz9 variant)
  fa6b931d903050d2837bb557482f1669d8767ad12b1c340e68192a85de873215
B = graphlaw(RDFC-1.0 N-Quads of either)
  37eef97df291cd1de78fc2b5bb9009490cc6be459e57818a9c26c30d58e939bc
```

`A` is not merely different from `B`; `A` is not well-defined, because it depends on the
arbitrary blank-node labels. `B` is a single value for both variants, because RDFC-1.0
rewrote both to `_:c14n0` before graphlaw ever saw them:

```text
<http://example.org/a> <http://example.org/p> _:c14n0 .
_:c14n0 <http://example.org/p> <http://example.org/c> .
```

So pre-canonicalizing with RDF.ex **repairs** graphlaw's blank-node non-invariance. A
receipt that wants a graphlaw-side BLAKE3 identity that is actually an identity should carry
`B`, computed over `CanonicalGraph.canonical_nquads/1` output, never `A` over raw Turtle.

This whole result is a standing executable artifact, not a prose claim:
`test/ash_a2a/semantic/canonical_graph_three_way_agreement_test.exs` asserts both the
agreement and the divergence against the real wasm law package in a real `node` process. It
skips visibly, naming what is missing, on a branch where the vendored artifact is absent --
it never substitutes a double for the engine under comparison.

## The wasm bridge UTF-8 guard (applied at merge)

This correction was written on a branch cut from `main` before the wasm bridge landed, so it
specified the bridge fix rather than editing the bridge. On `main` the bridge module is
`AshA2A.GraphLaw.WasmexHost` (`lib/ash_a2a/graph_law/wasmex_host.ex`, renamed at merge from
the bridge branch's `AshA2A.GraphLaw.Wasm` to avoid colliding with `main`'s node-subprocess
host of that name), and every export taking a Rust `&str` rejects non-UTF-8 input before
`transact/4`:

```elixir
def graph_hash(ttl, server \\ __MODULE__, timeout \\ @default_timeout) when is_binary(ttl) do
  with :ok <- ensure_utf8(ttl),
       {:ok, raw} <- transact(server, "graph_hash", [ttl], timeout) do
    as_plain_string(raw)
  end
end
```

`WasmexHost.ensure_utf8/1` delegates to `AshA2A.Semantic.CanonicalGraph.ensure_utf8/1`, so
there is one encoding guard and one byte-offset scanner in the repository. It returns `:ok`
or `{:error, {:invalid_encoding, byte_offset}}`, so the `with` short-circuits into the error
channel, typed as `WasmexHost`'s `t:encoding_error/0`. `blake3_hex/3`, `run_hooks/4` and
`validate_all/7` take the same treatment, and so must any future export whose Rust signature
takes `&str` rather than `&[u8]`.

The vendored 3.2MB wasm artifact and its dependency-free node host
(`priv/graphlaw/praxis_graphlaw.wasm`, `priv/graphlaw/host/graphlaw_host.mjs`) are present
on `main`, so the three-way agreement test runs for real rather than skipping.

## Relation to the other digests

One S12 identity path, several deliberately distinct digests, each named for what it is:

| Module / field | What it computes | S12 identity? |
| --- | --- | --- |
| `CanonicalGraph.canonical_digest/1` | RDFC-1.0 -> sorted N-Quads -> SHA-256 | **Yes** -- the one path |
| `AdmissionPipeline` `canonical_graph_hash` | `CanonicalGraph.canonical_digest/1` | Yes, via the one path |
| `CanonicalDigest.canonical_digest/2` | engine `graph_hash`, parse-back gated | No -- engine digest |
| `AdmissionHash` `graph_digest` | engine `graph_hash` (`"praxis-graphlaw/graph_hash"`) | No -- engine digest |
| `Ontology.canonical_digest/2` | engine `graph_hash` over N-Triples | No -- engine digest |
| `CanonicalTermDigest.digest/1` | SHA-256 over an Elixir term encoding | No -- not a graph digest |
| `Envelope.evidence_digest/1` | SHA-256 over a sorted key=value map | No -- not a graph digest |

The engine digests keep their contract that every digest comes from the same wasm bytes a
non-BEAM peer executes, so they are not rewired onto RDF.ex; they record which algorithm
produced them and are never described as RDFC-1.0.

## See Also

- `lib/ash_a2a/semantic/canonical_graph.ex` -- the S12 primitive itself
- `test/ash_a2a/semantic/canonical_graph_test.exs` -- the contract, incl. both defects
- `test/ash_a2a/semantic/canonical_graph_three_way_agreement_test.exs` -- cross-engine
  conformance against the real wasm law package
- `lib/ash_a2a/graph_law/wasmex_host.ex` -- the in-BEAM wasm host whose string exports run
  the `ensure_utf8/1` guard
- `docs/explanation/graphlaw-wasm-integration.md` -- the vendoring pipeline
- `docs/explanation/architecture.md` -- where the semantic layer sits overall
- RDF Dataset Canonicalization 1.0 (RDFC-1.0), W3C: <https://www.w3.org/TR/rdf-canon/>
