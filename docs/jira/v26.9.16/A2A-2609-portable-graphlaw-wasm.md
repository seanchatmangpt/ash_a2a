# A2A-2609: manufacture a content-addressed portable `graphlaw.wasm`

- **Status**: OPEN
- **Severity**: High
- **Standing**: `PARTIAL_ALIVE`
- **Owning repos**: `seanchatmangpt/ggen`, `seanchatmangpt/praxis`, `seanchatmangpt/unrdf`
- **Reuse**: current `praxis-graphlaw` N3/Datalog/SPARQL/SHACL/ShEx engine and deterministic hashing

## Problem

GraphLaw is real on the native path, but the ecosystem does not yet have one exact content-addressed WASM law artifact whose semantics can be exercised unchanged across host runtimes. Without that artifact, each host integration can still become a separate interpretation boundary.

## Required change

Produce `graphlaw.wasm` as a manufactured projection from a pinned GraphLaw source/toolchain identity with a narrow ABI for:

- load admitted graph/state;
- evaluate supported admission/query/rule operations;
- return typed result/refusal;
- emit deterministic receipt material sufficient to bind input, profile, operation and output.

The WASM module must not acquire host authority or perform arbitrary host I/O.

## Laws

1. Same module hash + same admitted input + same profile + same operation => same semantic result bytes.
2. Host runtime differences cannot alter law semantics.
3. Unsupported language constructs are typed refusals, never silent fallback.
4. No network/filesystem/shell capability is imported unless explicitly required and admitted; default law module imports none.
5. Module identity is content-addressed and recorded in every admission receipt it participates in.
6. Native and WASM paths must have a declared parity boundary, not an assumed one.

## Chicago falsifiers

1. One fixture produces the same admitted/refused result under at least two independent WASM hosts.
2. A known unsupported SPARQL construct is refused identically by both hosts.
3. Changing one byte of the WASM artifact changes module identity and invalidates a pinned receipt.
4. A host cannot inject authority through the law ABI.
5. Native-vs-WASM semantic parity fixtures fail if one path diverges.

## Definition of done

- deterministic build recipe and pinned toolchain exist;
- artifact hash is emitted and consumed by receipts;
- at least two host runtimes execute the same fixtures;
- no runtime `ALIVE` claim is made beyond the exact tested hosts/operations.
