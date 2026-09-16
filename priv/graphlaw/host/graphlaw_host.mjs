// Minimal, dependency-free WebAssembly host for the vendored
// praxis-graphlaw-wasm module.
//
// This file exists because wasm-pack's generated JS glue targets a specific
// JS host (bundler / web / nodejs) and none of those shapes is usable from
// the BEAM. Rather than depend on that glue, this host instantiates the raw
// `.wasm` directly and implements the wasm-bindgen string ABI by hand.
//
// The module imports EXACTLY two host functions (measured, see
// docs/explanation/graphlaw-wasm-integration.md):
//   __wbindgen_object_drop_ref              -> no-op
//   __wbg_getRandomValues_<hash>            -> fill (ptr,len) with random bytes
// The import MODULE name differs per wasm-pack target, so it is discovered
// from the module's own import list instead of being hardcoded.
//
// Protocol (line-oriented, so the BEAM side never has to parse partial JSON):
//   argv[2]: path to a file holding one JSON request object, OR
//   stdin   : that same JSON object, when no argv[2] is given.
//            {"wasm":"<abs path>","calls":[{"fn":"graph_hash","args":["..."]}]}
// The file form exists because Elixir's System.cmd/3 has no `:input` option;
// the stdin form keeps the host usable by hand from a shell.
//   stdout : one JSON object
//            {"ok":true,"results":["..."],"exports":[...],"imports":[...]}
//            {"ok":false,"code":"...","message":"..."}
// Exit code is 0 on {"ok":true} and 1 otherwise.

import fs from 'node:fs';

function fail(code, message) {
  process.stdout.write(JSON.stringify({ ok: false, code, message }) + '\n');
  process.exit(1);
}

function readRequest() {
  const fromFile = process.argv[2];
  try {
    return fs.readFileSync(fromFile === undefined ? 0 : fromFile, 'utf8');
  } catch (e) {
    fail('request_read_failed', String(e && e.message ? e.message : e));
  }
}

const raw = readRequest();
let req;
try {
  req = JSON.parse(raw);
} catch (e) {
  fail('bad_request_json', String(e && e.message ? e.message : e));
}

if (!req || typeof req.wasm !== 'string') {
  fail('bad_request_shape', 'request must be {"wasm": path, "calls": [...]}');
}

let bytes;
try {
  bytes = fs.readFileSync(req.wasm);
} catch (e) {
  fail('wasm_read_failed', String(e && e.message ? e.message : e));
}

let mod;
try {
  mod = new WebAssembly.Module(bytes);
} catch (e) {
  fail('wasm_compile_failed', String(e && e.message ? e.message : e));
}

const declaredImports = WebAssembly.Module.imports(mod);
const declaredExports = WebAssembly.Module.exports(mod).map((x) => x.name);

// Build the import object from what the module actually declares, so this
// host works across wasm-pack targets (which vary the glue module name).
const imports = {};
let unknownImport = null;
for (const imp of declaredImports) {
  imports[imp.module] = imports[imp.module] || {};
  if (imp.name === '__wbindgen_object_drop_ref') {
    imports[imp.module][imp.name] = () => {};
  } else if (imp.name.startsWith('__wbg_getRandomValues_')) {
    imports[imp.module][imp.name] = (ptr, len) => {
      const view = new Uint8Array(inst.exports.memory.buffer, ptr, len);
      globalThis.crypto.getRandomValues(view);
    };
  } else if (imp.kind === 'function') {
    unknownImport = `${imp.module}::${imp.name}`;
    // Supplying a throwing stub keeps instantiation itself valid so the
    // caller sees a precise runtime error rather than a link error.
    imports[imp.module][imp.name] = () => {
      throw new Error(`unstubbed host import ${unknownImport}`);
    };
  }
}

let inst;
try {
  inst = new WebAssembly.Instance(mod, imports);
} catch (e) {
  fail('wasm_instantiate_failed', String(e && e.message ? e.message : e));
}

const E = inst.exports;
const enc = new TextEncoder();
const dec = new TextDecoder();
const mem = () => new Uint8Array(E.memory.buffer);
const dv = () => new DataView(E.memory.buffer);

// wasm-bindgen ABI (confirmed by real execution):
//   __wbindgen_export2(len, align)                  -> ptr     (malloc)
//   __wbindgen_export4(ptr, len, align)             -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)            -> retptr
// A String-returning fn taking N string params is called as
//   fn(retptr, ptr0, len0, ..., ptrN, lenN)
// and writes two little-endian i32 at retptr+0 / retptr+4 => (ptr, len).
function putStr(s) {
  const b = enc.encode(s);
  const p = E.__wbindgen_export2(b.length, 1);
  mem().set(b, p);
  return [p, b.length];
}

function callString(fn, strs) {
  const retptr = E.__wbindgen_add_to_stack_pointer(-16);
  const args = [];
  for (const s of strs) {
    const [p, l] = putStr(s);
    args.push(p, l);
  }
  E[fn](retptr, ...args);
  const r0 = dv().getInt32(retptr + 0, true);
  const r1 = dv().getInt32(retptr + 4, true);
  const out = dec.decode(mem().slice(r0, r0 + r1));
  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(r0, r1, 1);
  return out;
}

const calls = Array.isArray(req.calls) ? req.calls : [];
const results = [];
for (const c of calls) {
  if (!c || typeof c.fn !== 'string') {
    fail('bad_call_shape', 'each call must be {"fn": name, "args": [strings]}');
  }
  if (typeof E[c.fn] !== 'function') {
    fail('unknown_export', `wasm module does not export a function ${c.fn}`);
  }
  const args = Array.isArray(c.args) ? c.args : [];
  try {
    results.push(callString(c.fn, args));
  } catch (e) {
    fail('wasm_call_failed', `${c.fn}: ${String(e && e.message ? e.message : e)}`);
  }
}

process.stdout.write(
  JSON.stringify({
    ok: true,
    results,
    exports: declaredExports,
    imports: declaredImports.map((i) => `${i.module}::${i.name}`),
  }) + '\n',
);
