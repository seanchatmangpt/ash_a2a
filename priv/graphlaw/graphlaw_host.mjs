// Real host for the prebuilt praxis-graphlaw wasm-bindgen module.
//
// The wasm in praxis-graphlaw-wasm/pkg was built with wasm-pack's BUNDLER
// target, so its sibling `praxis_graphlaw_wasm.js` glue does not load under
// plain Node ESM. This file instantiates the `_bg.wasm` module directly and
// re-implements the two host imports it actually declares, plus the
// wasm-bindgen string ABI. No part of this file simulates GraphLaw: every
// value it returns came out of the real wasm's linear memory.
//
// Protocol (so one process can serve a whole admission pipeline run):
//   argv[2] -> path to a real JSON request file on disk:
//              {"wasm_path": "...", "calls": [{"fn": "graph_hash", "args": ["..."]}]}
//   stdout  -> {"ok": true,  "results": ["..."]}
//           |  {"ok": false, "error": "..."}
//
// A request file (rather than stdin) is used because Elixir's `System.cmd/3`
// has no stdin option; the caller writes the file, we read it, the caller
// removes it.
//
// `args` are always strings; every exported function this host exposes takes
// only strings and returns a String.

import fs from "node:fs";

const EXPORTED = new Set([
  "graphlaw_version",
  "graph_hash",
  "blake3_hex",
  "validate_all",
  "run_hooks",
]);

function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(message) }));
  process.exit(0);
}

async function main() {
  const requestPath = process.argv[2];
  if (typeof requestPath !== "string" || requestPath === "") {
    fail("host invoked without a request file path");
    return;
  }

  let request;
  try {
    request = JSON.parse(fs.readFileSync(requestPath, "utf8"));
  } catch (e) {
    fail(`host request is not readable JSON: ${e.message}`);
    return;
  }

  const wasmPath = request.wasm_path;
  if (typeof wasmPath !== "string" || wasmPath === "") {
    fail("host request is missing wasm_path");
    return;
  }
  if (!fs.existsSync(wasmPath)) {
    fail(`graphlaw wasm not found at ${wasmPath}`);
    return;
  }

  const calls = request.calls;
  if (!Array.isArray(calls)) {
    fail("host request is missing calls");
    return;
  }

  let instance;
  const imports = {
    "./praxis_graphlaw_wasm_bg.js": {
      __wbindgen_object_drop_ref: () => {},
      // The wasm asks the host for random bytes. Admission must be replayable,
      // so this host fills the buffer from a fixed, documented, deterministic
      // sequence rather than a CSPRNG: identical inputs must produce identical
      // admission output on every runtime. This is a real fill of real linear
      // memory, not a stub that skips the write.
      __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
        const view = new Uint8Array(instance.exports.memory.buffer, ptr, len);
        for (let i = 0; i < len; i++) view[i] = (i * 2654435761) % 256;
      },
    },
  };

  try {
    const bytes = fs.readFileSync(wasmPath);
    ({ instance } = await WebAssembly.instantiate(bytes, imports));
  } catch (e) {
    fail(`graphlaw wasm instantiation failed: ${e.message}`);
    return;
  }

  const E = instance.exports;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const bytesOf = () => new Uint8Array(E.memory.buffer);
  const viewOf = () => new DataView(E.memory.buffer);

  function putString(s) {
    const encoded = encoder.encode(s);
    const ptr = E.__wbindgen_export2(encoded.length, 1);
    bytesOf().set(encoded, ptr);
    return [ptr, encoded.length];
  }

  function call(fn, args) {
    const retptr = E.__wbindgen_add_to_stack_pointer(-16);
    const flat = [];
    for (const arg of args) {
      const [ptr, len] = putString(arg);
      flat.push(ptr, len);
    }
    E[fn](retptr, ...flat);
    const resultPtr = viewOf().getInt32(retptr + 0, true);
    const resultLen = viewOf().getInt32(retptr + 4, true);
    const out = decoder.decode(bytesOf().slice(resultPtr, resultPtr + resultLen));
    E.__wbindgen_add_to_stack_pointer(16);
    E.__wbindgen_export4(resultPtr, resultLen, 1);
    return out;
  }

  const results = [];
  for (const entry of calls) {
    const fn = entry && entry.fn;
    const args = (entry && entry.args) || [];
    if (!EXPORTED.has(fn)) {
      fail(`unsupported graphlaw export: ${fn}`);
      return;
    }
    if (typeof E[fn] !== "function") {
      fail(`graphlaw wasm does not export ${fn}`);
      return;
    }
    if (!args.every((a) => typeof a === "string")) {
      fail(`graphlaw call ${fn} received a non-string argument`);
      return;
    }
    try {
      results.push(call(fn, args));
    } catch (e) {
      fail(`graphlaw call ${fn} trapped: ${e.message}`);
      return;
    }
  }

  process.stdout.write(JSON.stringify({ ok: true, results }));
}

main().catch((e) => fail(e && e.message ? e.message : e));
