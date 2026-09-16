// Real host-side driver for the prebuilt praxis-graphlaw wasm module.
//
// The pkg/ glue shipped by wasm-pack targets BUNDLER, so it cannot be
// imported under plain Node ESM. This file instantiates the raw
// `praxis_graphlaw_wasm_bg.wasm` directly and reimplements only the
// wasm-bindgen string ABI needed to call its String-returning exports.
//
// Protocol (so one process can serve many calls -- instantiating a 3.2MB
// module per call would dominate cost):
//   stdin  : {"wasm":"<abs path>","calls":[{"fn":"graph_hash","args":["..."]}]}
//   stdout : {"ok":true,"results":[{"ok":"<string>"}|{"error":"..."}]}
//   stdout : {"ok":false,"error":"..."}  on a whole-process failure
//
// Confirmed wasm-bindgen ABI (measured against this exact module):
//   __wbindgen_export2(len, align)                 -> ptr     (malloc)
//   __wbindgen_export4(ptr, len, align)            -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)           -> retptr
//   fn(retptr, ptr0, len0, ptr1, len1, ...)        -> ()
//   then two little-endian i32 at retptr+0/+4 give (resultPtr, resultLen).
import fs from 'node:fs';

function readStdin() {
  return new Promise((resolve, reject) => {
    let buf = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => (buf += d));
    process.stdin.on('end', () => resolve(buf));
    process.stdin.on('error', reject);
  });
}

function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(message) }));
  process.exit(0);
}

const raw = await readStdin();

let request;
try {
  request = JSON.parse(raw);
} catch (e) {
  fail(`stdin is not valid JSON: ${e.message}`);
}

const wasmPath = request.wasm;
if (typeof wasmPath !== 'string' || wasmPath.length === 0) {
  fail('request.wasm must be a non-empty absolute path string');
}
if (!fs.existsSync(wasmPath)) {
  fail(`wasm module not found at ${wasmPath}`);
}

const calls = Array.isArray(request.calls) ? request.calls : null;
if (calls === null) {
  fail('request.calls must be an array');
}

let inst;
const imports = {
  './praxis_graphlaw_wasm_bg.js': {
    __wbindgen_object_drop_ref: () => {},
    // The module only uses this to seed blank-node/bnode-label randomness.
    // A deterministic fill keeps repeated runs byte-identical, which is
    // exactly what a conformance court needs.
    __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
      const m = new Uint8Array(inst.exports.memory.buffer, ptr, len);
      for (let i = 0; i < len; i++) m[i] = (i * 2654435761) % 256;
    },
  },
};

try {
  const bytes = fs.readFileSync(wasmPath);
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

function callString(fnName, strs) {
  const fn = E[fnName];
  if (typeof fn !== 'function') {
    throw new Error(`wasm module exports no function named ${fnName}`);
  }
  const rp = E.__wbindgen_add_to_stack_pointer(-16);
  const args = [];
  for (const s of strs) {
    const [p, l] = putStr(s);
    args.push(p, l);
  }
  fn(rp, ...args);
  const r0 = dv().getInt32(rp + 0, true);
  const r1 = dv().getInt32(rp + 4, true);
  const out = dec.decode(mem().slice(r0, r0 + r1));
  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(r0, r1, 1);
  return out;
}

const results = [];
for (const call of calls) {
  try {
    const fnName = call && call.fn;
    const args = (call && call.args) || [];
    if (typeof fnName !== 'string') {
      results.push({ error: 'call.fn must be a string' });
      continue;
    }
    if (!Array.isArray(args) || args.some((a) => typeof a !== 'string')) {
      results.push({ error: 'call.args must be an array of strings' });
      continue;
    }
    results.push({ ok: callString(fnName, args) });
  } catch (e) {
    results.push({ error: String(e && e.message ? e.message : e) });
  }
}

process.stdout.write(JSON.stringify({ ok: true, results }));
