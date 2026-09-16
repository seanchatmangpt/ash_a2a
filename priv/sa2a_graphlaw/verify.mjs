#!/usr/bin/env node
// Real GraphLaw wasm driver for the SA2A conformance corpus.
//
// Usage:  node verify.mjs <corpus-dir> <wasm-path>
// Emits one JSON object on stdout; exits 0 on success, non-zero on failure.
//
// WHY THIS FILE EXISTS
// The prebuilt praxis-graphlaw wasm ships with wasm-bindgen glue targeted at a
// BUNDLER, which does not load under plain Node ESM. This module instantiates
// the wasm directly and implements the wasm-bindgen ABI by hand, so the corpus's
// recorded measurements can be re-verified against the real engine from any
// host, with no bundler and no npm install.
//
// THE ABI (confirmed against the real artifact, not derived from docs):
//   __wbindgen_export2(len, align)                -> ptr     (malloc)
//   __wbindgen_export3(ptr, oldLen, newLen, align)-> ptr     (realloc)
//   __wbindgen_export4(ptr, len, align)           -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)          -> retptr  (restore with +16)
// A String-returning fn with N string params is called as
//   fn(retptr, ptr0, len0, ptr1, len1, ...)
// then two little-endian i32 at retptr+0 / retptr+4 give (resultPtr, resultLen).
//
// The wasm imports exactly two host functions. `getRandomValues` is filled
// DETERMINISTICALLY on purpose: this driver exists to check reproducibility, so
// a real RNG here would be the one thing that could make an identical input
// produce a different digest.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [, , CORPUS, WASM_PATH] = process.argv;
if (!CORPUS || !WASM_PATH) {
  console.log(JSON.stringify({ error: 'usage: verify.mjs <corpus-dir> <wasm-path>' }));
  process.exit(2);
}
if (!fs.existsSync(WASM_PATH)) {
  console.log(JSON.stringify({ error: `wasm not found: ${WASM_PATH}` }));
  process.exit(3);
}

const wasmBytes = fs.readFileSync(WASM_PATH);
let inst;
({ instance: inst } = await WebAssembly.instantiate(wasmBytes, {
  './praxis_graphlaw_wasm_bg.js': {
    __wbindgen_object_drop_ref: () => {},
    __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
      const m = new Uint8Array(inst.exports.memory.buffer, ptr, len);
      for (let i = 0; i < len; i++) m[i] = (i * 2654435761) % 256;
    },
  },
}));

const E = inst.exports;
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const mem = () => new Uint8Array(E.memory.buffer);
const view = () => new DataView(E.memory.buffer);

function putStr(s) {
  const b = encoder.encode(s);
  const p = E.__wbindgen_export2(b.length, 1);
  mem().set(b, p);
  return [p, b.length];
}

function call(fn, ...strs) {
  const retptr = E.__wbindgen_add_to_stack_pointer(-16);
  const args = [];
  for (const s of strs) {
    const [p, l] = putStr(s);
    args.push(p, l);
  }
  E[fn](retptr, ...args);
  const r0 = view().getInt32(retptr + 0, true);
  const r1 = view().getInt32(retptr + 4, true);
  const out = decoder.decode(mem().slice(r0, r0 + r1));
  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(r0, r1, 1);
  return out;
}

// Every filesystem and engine fault below becomes a clean JSON `{error}` on
// stdout plus a non-zero exit, never a raw Node stack trace on stderr: the
// Elixir caller types the failure from the JSON, and a stack trace dumped past
// it would be noise in the middle of a test run.
if (!fs.existsSync(path.join(CORPUS, 'MANIFEST.json'))) {
  console.log(JSON.stringify({ error: `corpus MANIFEST.json not found under: ${CORPUS}` }));
  process.exit(4);
}

const read = (rel) => fs.readFileSync(path.join(CORPUS, rel), 'utf8');

let manifest;
try {
  manifest = JSON.parse(read('MANIFEST.json'));
} catch (e) {
  console.log(JSON.stringify({ error: `unreadable MANIFEST.json: ${e.message}` }));
  process.exit(4);
}

const profile = read('profile.ttl');
const shapesFull = read('shapes.shacl.ttl');
const shapesViolations = read('shapes.violations.shacl.ttl');
const shapesWarnings = read('shapes.warnings.shacl.ttl');
const shexSchema = read('schema.shex');
const shapeMap = read('shape_map.json');
const rules = read('rules/denials.n3');
const hooks = read('hooks/admitted_hooks.ttl');
const event = read('event.ttl');

// Must match AshA2A.SA2A.Corpus.law_graph/2 and MANIFEST.composition.law_graph.
const lawGraph = (subject) => [subject, rules, hooks].join('\n');

function validate(subject, shapes) {
  const raw = call('validate_all', lawGraph(subject), profile, shapes, shexSchema, shapeMap);
  const o = JSON.parse(raw);
  if (o.error) return { error: o.error };
  const shacl = o.dialects.find((d) => d.dialect === 'SHACL');
  return {
    dialects: Object.fromEntries(o.dialects.map((d) => [d.dialect, d.status])),
    shacl: { status: shacl.status, results: shacl.triples_out },
    replay: o.replay,
  };
}

const vectors = {};
try {
  for (const rel of Object.keys(manifest.files).filter((f) => f.endsWith('.expected.json'))) {
    const sidecar = JSON.parse(read(rel));
    const subject = read(sidecar.file);
    const full = validate(subject, shapesFull);
    const hooksRun = JSON.parse(call('run_hooks', lawGraph(subject), event));

    vectors[sidecar.vector] = {
      file: sidecar.file,
      graph_hash: call('graph_hash', subject),
      law_graph_hash: call('graph_hash', lawGraph(subject)),
      dialects: full.dialects,
      shacl_by_severity_partition: {
        full: full.shacl,
        violations_only: validate(subject, shapesViolations).shacl,
        warnings_only: validate(subject, shapesWarnings).shacl,
      },
      run_hooks: hooksRun.error
        ? { error: hooksRun.error }
        : {
            status: hooksRun.status,
            verdicts: hooksRun.verdicts.length,
            receipts: hooksRun.receipts.length,
            schedule: hooksRun.schedule,
          },
      replay: full.replay,
    };
  }
} catch (e) {
  console.log(JSON.stringify({ error: `measurement failed: ${e.message}` }));
  process.exit(5);
}

console.log(
  JSON.stringify({
    graphlaw_version: call('graphlaw_version'),
    wasm_sha256: crypto.createHash('sha256').update(wasmBytes).digest('hex'),
    wasm_bytes: wasmBytes.length,
    blake3_abc: call('blake3_hex', 'abc'),
    vectors,
  }),
);
