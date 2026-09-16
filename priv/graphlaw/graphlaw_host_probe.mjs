// Minimal, dependency-free host for praxis-graphlaw's wasm-bindgen module.
//
// WHY THIS FILE EXISTS: the prebuilt pkg/ glue (praxis_graphlaw_wasm.js) is a
// wasm-bindgen BUNDLER-target artifact -- it does not load under plain Node ESM
// or under any non-bundler host as-is. This file instantiates the same
// .wasm bytes manually against the wasm-bindgen ABI, so the REAL Rust
// semantic engine (RDFC-1.0 canonicalization, BLAKE3, SHACL/ShEx validation,
// N3 hooks) is callable from a host it was not built for.
//
// It is deliberately a THIN transport: it adds no semantics of its own.
// Every value it prints came out of the real wasm module.
//
// Contract: argv = [op, ...file paths]. Prints ONE JSON object to stdout:
//   {"ok":true,"op":...,"result":...}   or   {"ok":false,"op":...,"error":...}
// Always exits 0 on a well-formed refusal so the caller reads the typed JSON
// error rather than guessing from an exit code (same discipline as the
// wasm's own {"error": "..."} return convention).

import fs from 'node:fs';

function emit(obj) {
  process.stdout.write(JSON.stringify(obj));
}

const [, , op, ...rest] = process.argv;

if (!op) {
  emit({ ok: false, op: null, error: 'missing_op' });
  process.exit(0);
}

const wasmPath = process.env.GRAPHLAW_WASM;
if (!wasmPath) {
  emit({ ok: false, op, error: 'missing_GRAPHLAW_WASM_env' });
  process.exit(0);
}
if (!fs.existsSync(wasmPath)) {
  emit({ ok: false, op, error: 'wasm_not_found: ' + wasmPath });
  process.exit(0);
}

let inst;
const imports = {
  './praxis_graphlaw_wasm_bg.js': {
    __wbindgen_object_drop_ref: () => {},
    // The module imports exactly two host functions. This one fills a buffer
    // in linear memory with bytes. Filled DETERMINISTICALLY on purpose: this
    // host exists to make canonical digests reproducible across runtimes, and
    // a real CSPRNG here would be the one nondeterministic input in the path.
    // No call surfaced by this host consumes randomness for security.
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
  emit({ ok: false, op, error: 'instantiate_failed: ' + String(e && e.message) });
  process.exit(0);
}

const E = inst.exports;
const enc = new TextEncoder();
const dec = new TextDecoder();
const mem = () => new Uint8Array(E.memory.buffer);
const dv = () => new DataView(E.memory.buffer);

// wasm-bindgen ABI (confirmed against this exact module):
//   __wbindgen_export2(len, align)                  -> ptr     (malloc)
//   __wbindgen_export4(ptr, len, align)             -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)            -> retptr
// A String-returning fn with N string params is called as
//   fn(retptr, ptr0, len0, ptr1, len1, ...)
// then two little-endian i32 at retptr+0 / retptr+4 give (resultPtr, resultLen).
function putStr(s) {
  const b = enc.encode(s);
  const p = E.__wbindgen_export2(b.length, 1);
  mem().set(b, p);
  return [p, b.length];
}

function call(fn, ...strs) {
  if (typeof E[fn] !== 'function') throw new Error('no_such_export: ' + fn);
  const rp = E.__wbindgen_add_to_stack_pointer(-16);
  const args = [];
  for (const s of strs) {
    const [p, l] = putStr(s);
    args.push(p, l);
  }
  E[fn](rp, ...args);
  const r0 = dv().getInt32(rp + 0, true);
  const r1 = dv().getInt32(rp + 4, true);
  const out = dec.decode(mem().slice(r0, r0 + r1));
  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(r0, r1, 1);
  return out;
}

const readArg = (i) => {
  const p = rest[i];
  if (p === undefined) throw new Error('missing_arg_' + i);
  return fs.readFileSync(p, 'utf8');
};

try {
  let result;
  switch (op) {
    case 'version':
      result = call('graphlaw_version');
      break;
    case 'graph_hash':
      result = call('graph_hash', readArg(0));
      break;
    case 'blake3_hex_file':
      result = call('blake3_hex', readArg(0));
      break;
    case 'validate_all':
      // validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map)
      result = call(
        'validate_all',
        readArg(0),
        readArg(1),
        readArg(2),
        readArg(3),
        readArg(4),
      );
      break;
    case 'run_hooks':
      result = call('run_hooks', readArg(0), readArg(1));
      break;
    default:
      emit({ ok: false, op, error: 'unknown_op: ' + op });
      process.exit(0);
  }
  emit({ ok: true, op, result });
} catch (e) {
  emit({ ok: false, op, error: String((e && e.message) || e) });
}
