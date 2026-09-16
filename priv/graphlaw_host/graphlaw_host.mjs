// Runtime B of the SA2A conformance court: a standalone, out-of-BEAM
// WebAssembly host for the real prebuilt praxis-graphlaw WASM module.
//
// This process is spawned by AshA2A.GraphLaw.RuntimeB as a real OS
// subprocess and speaks Erlang's {:packet, 4} framing on stdin/stdout:
// every message is a 4-byte big-endian length followed by that many bytes of
// UTF-8 JSON. stdout carries framed responses and NOTHING else -- any stray
// write would desynchronise the stream, so all diagnostics go to stderr.
//
// It deliberately re-implements the wasm-bindgen ABI by hand rather than
// importing pkg/praxis_graphlaw_wasm.js: that glue is built for the bundler
// target and is not loadable as a plain ES module. Speaking the ABI directly
// is also the point -- it is what makes this a genuinely independent host
// rather than a second copy of the same glue code.
//
// Request : {"id": <int>, "op": "call"|"descriptor"|"close",
//            "fn": "<name>", "args": ["<string>", ...]}
// Response: {"id": <int>, "ok": true, "result": "<string>"}
//         | {"id": <int>, "ok": false, "error": "<message>"}

import fs from 'node:fs';
import crypto from 'node:crypto';

const WASM_PATH = process.argv[2];
if (!WASM_PATH) {
  process.stderr.write('graphlaw_host: missing wasm path argument\n');
  process.exit(2);
}

const wasmBytes = fs.readFileSync(WASM_PATH);
const wasmDigest = crypto.createHash('sha256').update(wasmBytes).digest('hex');

// The identical deterministic sequence AshA2A.GraphLaw.Runtime pins:
//   byte(i) = (i * 2654435761) mod 256
// Host entropy here would make cross-runtime digest equality meaningless.
function deterministicRandomByte(i) {
  return (i * 2654435761) % 256;
}

let instance;
const imports = {
  './praxis_graphlaw_wasm_bg.js': {
    __wbindgen_object_drop_ref: () => {},
    __wbg_getRandomValues_3f44b700395062e5: (ptr, len) => {
      const view = new Uint8Array(instance.exports.memory.buffer, ptr, len);
      for (let i = 0; i < len; i++) view[i] = deterministicRandomByte(i);
    },
  },
};

const wasmModule = new WebAssembly.Module(wasmBytes);
instance = new WebAssembly.Instance(wasmModule, imports);
const E = instance.exports;

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const mem = () => new Uint8Array(E.memory.buffer);
const view = () => new DataView(E.memory.buffer);

const ARITY = {
  graphlaw_version: 0,
  validate_all: 5,
  graph_hash: 1,
  run_hooks: 2,
  blake3_hex: 1,
};

function putString(s) {
  const bytes = encoder.encode(s);
  const ptr = E.__wbindgen_export2(Math.max(bytes.length, 1), 1);
  mem().set(bytes, ptr);
  return [ptr, bytes.length];
}

function callGraphLaw(fn, args) {
  const expected = ARITY[fn];
  if (expected === undefined) throw new Error(`unknown graphlaw function: ${fn}`);
  if (args.length !== expected) {
    throw new Error(`arity mismatch for ${fn}: expected ${expected}, got ${args.length}`);
  }

  const retptr = E.__wbindgen_add_to_stack_pointer(-16);
  const flat = [];
  for (const arg of args) {
    const [ptr, len] = putString(arg);
    flat.push(ptr, len);
  }

  E[fn](retptr, ...flat);
  const resultPtr = view().getInt32(retptr + 0, true);
  const resultLen = view().getInt32(retptr + 4, true);
  const out = decoder.decode(mem().slice(resultPtr, resultPtr + resultLen));

  E.__wbindgen_add_to_stack_pointer(16);
  E.__wbindgen_export4(resultPtr, resultLen, 1);
  return out;
}

function handle(request) {
  switch (request.op) {
    case 'descriptor':
      return {
        id: request.id,
        ok: true,
        result: JSON.stringify({
          wasm_digest: wasmDigest,
          wasm_path: WASM_PATH,
          engine: engineIdentity(),
        }),
      };
    case 'call':
      return { id: request.id, ok: true, result: callGraphLaw(request.fn, request.args) };
    case 'close':
      return { id: request.id, ok: true, result: 'closing' };
    default:
      throw new Error(`unknown op: ${request.op}`);
  }
}

function engineIdentity() {
  // Reported, never asserted: whichever standalone engine is actually
  // executing this file names itself here, and the Elixir side surfaces it
  // verbatim in the receipt.
  const v = process.versions || {};
  if (v.v8) return `v8-${v.v8}`;
  if (v.javascriptcore) return `javascriptcore-${v.javascriptcore}`;
  return 'unknown';
}

// -- {:packet, 4} framing ---------------------------------------------------

function writeFrame(obj) {
  const payload = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  process.stdout.write(Buffer.concat([header, payload]));
}

let buffer = Buffer.alloc(0);

process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);

  for (;;) {
    if (buffer.length < 4) return;
    const len = buffer.readUInt32BE(0);
    if (buffer.length < 4 + len) return;

    const payload = buffer.subarray(4, 4 + len);
    buffer = buffer.subarray(4 + len);

    let request;
    try {
      request = JSON.parse(payload.toString('utf8'));
    } catch (e) {
      writeFrame({ id: -1, ok: false, error: `malformed request: ${e.message}` });
      continue;
    }

    try {
      writeFrame(handle(request));
      if (request.op === 'close') process.exit(0);
    } catch (e) {
      writeFrame({ id: request.id ?? -1, ok: false, error: e.message });
    }
  }
});

process.stdin.on('end', () => process.exit(0));
