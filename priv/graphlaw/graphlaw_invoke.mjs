// Real host binding for the prebuilt praxis-graphlaw WebAssembly module.
//
// This file is a HOST, not an engine. It contains no RDF logic whatsoever --
// every byte of parsing, hashing, validation and reasoning happens inside
// praxis_graphlaw_wasm_bg.wasm (the real Rust praxis-graphlaw build). All this
// does is move UTF-8 strings across the wasm-bindgen ABI boundary.
//
// The published pkg/praxis_graphlaw_wasm.js glue is a BUNDLER-target build and
// does not load under plain Node ESM, so the module is instantiated manually
// against its two real imports. The ABI below was established by a real
// execution of this exact wasm, not derived from documentation:
//
//   __wbindgen_export2(len, align)                -> ptr     (malloc)
//   __wbindgen_export3(ptr, oldLen, newLen, align)-> ptr     (realloc)
//   __wbindgen_export4(ptr, len, align)           -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)          -> retptr  (restore with +16)
//
// A String-returning export with N string parameters is called as
//   fn(retptr, ptr0, len0, ptr1, len1, ...)
// after which two little-endian i32 at retptr+0 and retptr+4 give
// (resultPtr, resultLen) into linear memory.
//
// Usage:  node graphlaw_invoke.mjs <wasm_path> <request_json_path>
// Request: {"calls": [{"fn": "graph_hash", "args": ["<ttl>"]}, ...]}
// Response (stdout): {"ok": true, "results": ["...", ...]}
//                 or {"ok": false, "error": "..."}

import fs from 'node:fs';
import { randomFillSync } from 'node:crypto';

function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(message) }));
  process.exit(0); // the Elixir side reads the JSON, not the exit code
}

const wasmPath = process.argv[2];
const requestPath = process.argv[3];

if (!wasmPath || !requestPath) {
  fail('usage: graphlaw_invoke.mjs <wasm_path> <request_json_path>');
}

let bytes;
let request;
try {
  bytes = fs.readFileSync(wasmPath);
} catch (e) {
  fail(`cannot read wasm at ${wasmPath}: ${e.message}`);
}
try {
  request = JSON.parse(fs.readFileSync(requestPath, 'utf8'));
} catch (e) {
  fail(`cannot read request at ${requestPath}: ${e.message}`);
}

let inst;
const imports = {
  './praxis_graphlaw_wasm_bg.js': {
    __wbindgen_object_drop_ref: () => {},
    // Real host entropy, exactly as a browser or Node host would supply it.
    // graph_hash/blake3_hex determinism is therefore a real, testable
    // property of the engine rather than an artefact of a fixed stub.
    __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
      randomFillSync(new Uint8Array(inst.exports.memory.buffer, ptr, len));
    },
  },
};

try {
  ({ instance: inst } = await WebAssembly.instantiate(bytes, imports));
} catch (e) {
  fail(`wasm instantiation failed: ${e.message}`);
}

const E = inst.exports;
const enc = new TextEncoder();
const dec = new TextDecoder();
const mem = () => new Uint8Array(E.memory.buffer);
const dv = () => new DataView(E.memory.buffer);

function putStr(s) {
  const b = enc.encode(s);
  const p = E.__wbindgen_export2(b.length, 1);
  mem().set(b, p);
  return [p, b.length];
}

function callString(fn, args) {
  if (typeof E[fn] !== 'function') {
    throw new Error(`export not found: ${fn}`);
  }
  const retptr = E.__wbindgen_add_to_stack_pointer(-16);
  const packed = [];
  for (const a of args) {
    const [p, l] = putStr(String(a));
    packed.push(p, l);
  }
  E[fn](retptr, ...packed);
  const r0 = dv().getInt32(retptr + 0, true);
  const r1 = dv().getInt32(retptr + 4, true);
  const out = dec.decode(mem().slice(r0, r0 + r1));
  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(r0, r1, 1);
  return out;
}

try {
  const calls = Array.isArray(request.calls) ? request.calls : [];
  const results = calls.map((c) => callString(c.fn, Array.isArray(c.args) ? c.args : []));
  process.stdout.write(JSON.stringify({ ok: true, results, exports: Object.keys(E).length }));
} catch (e) {
  fail(e.message);
}
