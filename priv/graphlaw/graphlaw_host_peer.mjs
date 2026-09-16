// Real host shim for the prebuilt praxis-graphlaw wasm-bindgen module.
//
// The wasm at praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm is built
// for the wasm-bindgen BUNDLER target: its sibling .js glue does not load
// under plain Node ESM. This shim instantiates the module manually against
// the wasm-bindgen ABI instead, which is stable and fully documented below:
//
//   __wbindgen_export2(len, align)                -> ptr     (malloc)
//   __wbindgen_export4(ptr, len, align)           -> ()      (free)
//   __wbindgen_add_to_stack_pointer(-16)          -> retptr  (+16 restores)
//   String-returning fn with N string params:
//       fn(retptr, ptr0, len0, ptr1, len1, ...)
//   then two little-endian i32 at retptr+0 / retptr+4 => (resultPtr, resultLen)
//
// The module imports exactly two host functions, both trivially satisfiable.
//
// Protocol: one JSON request object -- read from the file named by
// `--request-file <path>` when that flag is present, otherwise from stdin --
// and one JSON response object on stdout.
//   {"fn":"graph_hash","args":["<ttl>"]} -> {"ok":true,"result":"<hex>"}
//   {"fn":"run_hooks","args":["<base ttl>","<event ttl>"]}
//   {"fn":"graphlaw_version","args":[]}
//   {"fn":"blake3_hex","args":["abc"]}
// Any failure -> {"ok":false,"error":"..."} on stdout, exit 0, so the calling
// Elixir port never has to distinguish crash-vs-refusal by exit code alone.

import fs from 'node:fs';

const ALLOWED = new Set(['graph_hash', 'run_hooks', 'graphlaw_version', 'blake3_hex', 'validate_all']);

function fail(error) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(error) }));
  process.exit(0);
}

async function main() {
  const wasmPath = process.env.GRAPHLAW_WASM;
  if (!wasmPath) fail('GRAPHLAW_WASM not set');
  if (!fs.existsSync(wasmPath)) fail(`wasm not found: ${wasmPath}`);

  const flagIndex = process.argv.indexOf('--request-file');
  const requestSource = flagIndex !== -1 ? process.argv[flagIndex + 1] : 0;

  let request;
  try {
    request = JSON.parse(fs.readFileSync(requestSource, 'utf8'));
  } catch (e) {
    fail(`bad request json: ${e.message}`);
  }

  const fn = request.fn;
  const args = request.args || [];
  if (!ALLOWED.has(fn)) fail(`function not allowed: ${fn}`);

  const bytes = fs.readFileSync(wasmPath);
  let inst;
  const imports = {
    './praxis_graphlaw_wasm_bg.js': {
      __wbindgen_object_drop_ref: () => {},
      // Deterministic on purpose: this host never needs cryptographic
      // randomness, and a deterministic fill keeps a digest reproducible
      // across peers, which is exactly what the portability claim needs.
      __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
        const m = new Uint8Array(inst.exports.memory.buffer, ptr, len);
        for (let i = 0; i < len; i++) m[i] = (i * 2654435761) % 256;
      },
    },
  };

  try {
    ({ instance: inst } = await WebAssembly.instantiate(bytes, imports));
  } catch (e) {
    fail(`instantiate failed: ${e.message}`);
  }

  const E = inst.exports;
  if (typeof E[fn] !== 'function') fail(`export missing: ${fn}`);

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

  try {
    const rp = E.__wbindgen_add_to_stack_pointer(-16);
    const flat = [];
    for (const s of args) {
      const [p, l] = putStr(String(s));
      flat.push(p, l);
    }
    E[fn](rp, ...flat);
    const r0 = dv().getInt32(rp + 0, true);
    const r1 = dv().getInt32(rp + 4, true);
    const out = dec.decode(mem().slice(r0, r0 + r1));
    E.__wbindgen_add_to_stack_pointer(16);
    E.__wbindgen_export4(r0, r1, 1);
    process.stdout.write(JSON.stringify({ ok: true, result: out }));
  } catch (e) {
    fail(`call failed: ${e.message}`);
  }
}

main().catch((e) => fail(e.message));
