//! Runtime B: a non-BEAM Wasmtime host for the *identical* praxis-graphlaw
//! WebAssembly artifact that the BEAM side loads.
//!
//! Protocol
//! --------
//! argv:   `graphlaw_host <path/to/praxis_graphlaw_wasm.wasm> [job.json]`
//!         (or set `GRAPHLAW_WASM` and pass no wasm argv). When a second argv
//!         is given the job JSON is read from that file instead of stdin --
//!         this is what the BEAM caller uses, because an Erlang port cannot
//!         half-close a child's stdin, so a job *file* is the only way to
//!         drive this binary from the BEAM with a real timeout.
//! stdin:  one JSON object, either
//!           `{"fn":"graph_hash","args":["@prefix ex: ..."]}`
//!         or a batch (amortizes the wasm compile across jobs)
//!           `{"jobs":[{"fn":"graph_hash","args":["..."]}, ...]}`
//! stdout: one JSON object, always carrying artifact identity:
//!           {"ok":"<string>","fn":"graph_hash","wasm_sha256":"<hex>",
//!            "wasm_bytes":N,"wasm_path":"...","runtime":"wasmtime",
//!            "runtime_version":"48.0.1","host":"graphlaw_host/0.1.0"}
//!         or, for a batch, `{"results":[ {"ok":..}|{"error":..}, .. ], ..}`
//!         or, on failure, `{"error":"...","code":"..."}` (plus identity when known).
//!
//! Exit code is `0` whenever a well-formed result (including a per-job error)
//! was printed, and `1` only for a fatal harness failure (unreadable wasm,
//! unparseable stdin, failed compile/instantiate) -- in which case an error
//! JSON is still printed to stdout.
//!
//! Artifact identity (RFC-SA2A-001 falsifier #1)
//! ---------------------------------------------
//! Every response carries the SHA-256 of the exact `.wasm` bytes this process
//! compiled. The conformance court can therefore *prove* Runtime A and
//! Runtime B ran the same artifact rather than assuming it.
//!
//! The wasm-bindgen ABI, and why this file speaks it directly
//! ----------------------------------------------------------
//! The vendored module is a wasm-bindgen *bundler*-target artifact. Its
//! generated JS glue only works inside a JS bundler, so a non-JS host must
//! speak the raw ABI:
//!   `__wbindgen_export2(len, align) -> ptr`            (malloc)
//!   `__wbindgen_export4(ptr, len, align)`              (free)
//!   `__wbindgen_add_to_stack_pointer(-16) -> retptr`   (+16 restores)
//! A `String`-returning function with N string parameters is called as
//! `f(retptr, ptr0, len0, ..)`, after which two little-endian `i32`s at
//! `retptr+0` / `retptr+4` give `(result_ptr, result_len)` into linear memory.
//! Argument strings are *moved* into the module (the Rust side inside the wasm
//! owns and frees them); only the result buffer is freed here.
//!
//! Host imports are discovered from the module rather than hardcoded, so the
//! two `./praxis_graphlaw_wasm_bg.js` imports are defined with whatever
//! signature the module actually declares.

use std::collections::BTreeMap;
use std::io::Read;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use wasmtime::{
    Caller, Engine, Extern, ExternType, Func, Linker, Memory, Module, Store, Val, ValType,
};

const HOST_ID: &str = concat!("graphlaw_host/", env!("CARGO_PKG_VERSION"));

/// The Wasmtime version this binary is pinned to. Kept in lockstep with the
/// `wasmtime = "=48.0.1"` exact-version pin in `Cargo.toml`; reported in every
/// response so a conformance receipt records which engine produced the answer.
const WASMTIME_VERSION: &str = "48.0.1";

/// Deterministic stand-in for `crypto.getRandomValues`.
///
/// This is a *conformance* host: two runs over the same input must agree
/// byte-for-byte, so real entropy would be a correctness bug here rather than
/// a feature. The byte sequence is intentionally identical to the reference
/// JavaScript shim (`(i * 2654435761) % 256`, Knuth's multiplicative constant)
/// so a JS host, this Wasmtime host, and a BEAM host all feed the module the
/// same "random" bytes. None of the conformance functions (`graph_hash`,
/// `blake3_hex`, `graphlaw_version`, `run_hooks`, `validate_all`) are
/// documented to consume randomness; this exists so that instantiation or any
/// incidental call site cannot introduce divergence.
fn deterministic_bytes(into: &mut [u8]) {
    for (i, b) in into.iter_mut().enumerate() {
        *b = ((i as u64).wrapping_mul(2_654_435_761) % 256) as u8;
    }
}

fn zero_val(ty: &ValType) -> Val {
    match ty {
        ValType::I64 => Val::I64(0),
        ValType::F32 => Val::F32(0),
        ValType::F64 => Val::F64(0),
        _ => Val::I32(0),
    }
}

/// An instantiated module plus the handful of exports the ABI needs.
struct Runtime {
    store: Store<()>,
    memory: Memory,
    exports: BTreeMap<&'static str, Func>,
}

const REQUIRED_EXPORTS: [&str; 8] = [
    "blake3_hex",
    "graph_hash",
    "graphlaw_version",
    "run_hooks",
    "validate_all",
    "__wbindgen_add_to_stack_pointer",
    "__wbindgen_export2",
    "__wbindgen_export4",
];

impl Runtime {
    fn new(engine: &Engine, module: &Module) -> Result<Self, String> {
        let mut linker: Linker<()> = Linker::new(engine);

        for imp in module.imports() {
            let ExternType::Func(ty) = imp.ty() else {
                return Err(format!(
                    "unsupported non-function import {}::{}",
                    imp.module(),
                    imp.name()
                ));
            };
            let import_module = imp.module().to_string();
            let import_name = imp.name().to_string();
            let results_ty: Vec<ValType> = ty.results().collect();
            let is_random = import_name.contains("getRandomValues");

            linker
                .func_new(
                    &import_module,
                    &import_name,
                    ty,
                    move |mut caller: Caller<'_, ()>, params: &[Val], results: &mut [Val]| {
                        if is_random {
                            if let (Some(Val::I32(ptr)), Some(Val::I32(len))) =
                                (params.first(), params.get(1))
                            {
                                if let Some(Extern::Memory(mem)) = caller.get_export("memory") {
                                    let (ptr, len) = (*ptr as usize, *len as usize);
                                    let data = mem.data_mut(&mut caller);
                                    if let Some(slice) = data.get_mut(ptr..ptr.saturating_add(len))
                                    {
                                        deterministic_bytes(slice);
                                    }
                                }
                            }
                        }
                        for (slot, ty) in results.iter_mut().zip(results_ty.iter()) {
                            *slot = zero_val(ty);
                        }
                        Ok(())
                    },
                )
                .map_err(|e| {
                    format!("failed to define import {import_module}::{import_name}: {e}")
                })?;
        }

        let mut store = Store::new(engine, ());
        let instance = linker
            .instantiate(&mut store, module)
            .map_err(|e| format!("instantiation failed: {e}"))?;

        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| "wasm module is missing required export `memory`".to_string())?;

        let mut exports = BTreeMap::new();
        for name in REQUIRED_EXPORTS {
            let f = instance
                .get_func(&mut store, name)
                .ok_or_else(|| format!("wasm module is missing required export `{name}`"))?;
            exports.insert(name, f);
        }

        Ok(Runtime {
            store,
            memory,
            exports,
        })
    }

    fn func(&self, name: &str) -> Result<Func, String> {
        self.exports
            .get(name)
            .copied()
            .ok_or_else(|| format!("unknown wasm export `{name}`"))
    }

    fn call_i32(&mut self, name: &str, args: &[i32], want_result: bool) -> Result<i32, String> {
        let f = self.func(name)?;
        let params: Vec<Val> = args.iter().map(|a| Val::I32(*a)).collect();
        let mut results = if want_result {
            vec![Val::I32(0)]
        } else {
            vec![]
        };
        f.call(&mut self.store, &params, &mut results)
            .map_err(|e| format!("`{name}` trapped: {e}"))?;
        if want_result {
            match results.first() {
                Some(Val::I32(v)) => Ok(*v),
                other => Err(format!("`{name}` returned unexpected {other:?}")),
            }
        } else {
            Ok(0)
        }
    }

    /// Copy `s` into the module's linear memory using its own allocator.
    /// Ownership of the allocation transfers into the module.
    fn put_str(&mut self, s: &str) -> Result<(i32, i32), String> {
        let bytes = s.as_bytes();
        let len =
            i32::try_from(bytes.len()).map_err(|_| "argument exceeds i32 length".to_string())?;
        let ptr = self.call_i32("__wbindgen_export2", &[len, 1], true)?;
        self.memory
            .write(&mut self.store, ptr as usize, bytes)
            .map_err(|e| format!("failed to write {len} bytes into wasm memory at {ptr}: {e}"))?;
        Ok((ptr, len))
    }

    fn read_i32(&self, at: usize) -> Result<i32, String> {
        let data = self.memory.data(&self.store);
        let slice = data
            .get(at..at + 4)
            .ok_or_else(|| format!("out-of-bounds i32 read at {at}"))?;
        Ok(i32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
    }

    /// Invoke a `String`-returning wasm-bindgen export with string arguments.
    fn call_string_fn(&mut self, name: &str, args: &[String]) -> Result<String, String> {
        let retptr = self.call_i32("__wbindgen_add_to_stack_pointer", &[-16], true)?;

        let mut abi_args: Vec<i32> = vec![retptr];
        for a in args {
            let (ptr, len) = self.put_str(a)?;
            abi_args.push(ptr);
            abi_args.push(len);
        }

        let call = self.call_i32(name, &abi_args, false);

        let out = match call {
            Ok(_) => {
                let r0 = self.read_i32(retptr as usize)?;
                let r1 = self.read_i32(retptr as usize + 4)?;
                let (ptr, len) = (r0 as usize, r1 as usize);
                let data = self.memory.data(&self.store);
                let bytes = data
                    .get(ptr..ptr.saturating_add(len))
                    .ok_or_else(|| format!("out-of-bounds result read at {ptr}+{len}"))?
                    .to_vec();
                let s = String::from_utf8(bytes)
                    .map_err(|e| format!("`{name}` returned non-UTF-8 bytes: {e}"))?;
                // Restore the shadow stack, then hand the result buffer back.
                self.call_i32("__wbindgen_add_to_stack_pointer", &[16], true)?;
                self.call_i32("__wbindgen_export4", &[r0, r1, 1], false)?;
                Ok(s)
            }
            Err(e) => {
                let _ = self.call_i32("__wbindgen_add_to_stack_pointer", &[16], true);
                Err(e)
            }
        };
        out
    }
}

fn main() {
    let wasm_path = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("GRAPHLAW_WASM").ok());

    let Some(wasm_path) = wasm_path else {
        fatal(
            "no wasm path given: pass it as argv[1] or set GRAPHLAW_WASM",
            "wasm_path_missing",
            None,
        );
    };

    let bytes = match std::fs::read(&wasm_path) {
        Ok(b) => b,
        Err(e) => fatal(
            &format!("cannot read wasm at {wasm_path}: {e}"),
            "wasm_unreadable",
            None,
        ),
    };

    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let identity = json!({
        "wasm_sha256": hex(&hasher.finalize()),
        "wasm_bytes": bytes.len(),
        "wasm_path": wasm_path,
        "runtime": "wasmtime",
        "runtime_version": WASMTIME_VERSION,
        "host": HOST_ID,
    });

    let mut input = String::new();
    match std::env::args().nth(2) {
        Some(job_file) => match std::fs::read_to_string(&job_file) {
            Ok(s) => input = s,
            Err(e) => fatal(
                &format!("cannot read job file {job_file}: {e}"),
                "job_file_unreadable",
                Some(&identity),
            ),
        },
        None => {
            if let Err(e) = std::io::stdin().read_to_string(&mut input) {
                fatal(
                    &format!("cannot read stdin: {e}"),
                    "stdin_unreadable",
                    Some(&identity),
                );
            }
        }
    }

    let request: Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(e) => fatal(
            &format!("stdin is not valid JSON: {e}"),
            "non_json_stdin",
            Some(&identity),
        ),
    };

    let batch = request.get("jobs").is_some();
    let jobs: Vec<Value> = match request.get("jobs") {
        Some(Value::Array(a)) => a.clone(),
        Some(_) => fatal("`jobs` must be an array", "bad_request", Some(&identity)),
        None => vec![request.clone()],
    };

    let engine = Engine::default();
    let module = match Module::new(&engine, &bytes) {
        Ok(m) => m,
        Err(e) => fatal(
            &format!("wasm compilation failed: {e}"),
            "wasm_compile_failed",
            Some(&identity),
        ),
    };

    let mut rt = match Runtime::new(&engine, &module) {
        Ok(rt) => rt,
        Err(e) => fatal(&e, "wasm_instantiation_failed", Some(&identity)),
    };

    let results: Vec<Value> = jobs.iter().map(|job| run_job(&mut rt, job)).collect();

    let mut out = identity.as_object().cloned().unwrap_or_default();
    if batch {
        out.insert("results".into(), Value::Array(results));
    } else if let Some(obj) = results
        .into_iter()
        .next()
        .as_ref()
        .and_then(Value::as_object)
    {
        for (k, v) in obj {
            out.insert(k.clone(), v.clone());
        }
    }
    println!("{}", Value::Object(out));
}

fn run_job(rt: &mut Runtime, job: &Value) -> Value {
    let Some(name) = job.get("fn").and_then(Value::as_str) else {
        return json!({"error": "job is missing string field `fn`", "code": "bad_job"});
    };

    let args: Vec<String> = match job.get("args") {
        None => vec![],
        Some(Value::Array(a)) => {
            let mut v = Vec::with_capacity(a.len());
            for item in a {
                match item.as_str() {
                    Some(s) => v.push(s.to_string()),
                    None => {
                        return json!({
                            "error": "every element of `args` must be a string",
                            "code": "bad_job"
                        })
                    }
                }
            }
            v
        }
        Some(_) => return json!({"error": "`args` must be an array", "code": "bad_job"}),
    };

    let expected = match name {
        "graphlaw_version" => 0usize,
        "graph_hash" | "blake3_hex" => 1,
        "run_hooks" => 2,
        "validate_all" => 5,
        other => {
            return json!({
                "error": format!("unsupported function `{other}`"),
                "code": "unsupported_fn"
            })
        }
    };

    if args.len() != expected {
        return json!({
            "error": format!("`{name}` takes {expected} argument(s), got {}", args.len()),
            "code": "bad_arity",
            "fn": name
        });
    }

    match rt.call_string_fn(name, &args) {
        Ok(s) => json!({"ok": s, "fn": name}),
        Err(e) => json!({"error": e, "code": "wasm_call_failed", "fn": name}),
    }
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

fn fatal(message: &str, code: &str, identity: Option<&Value>) -> ! {
    let mut out = identity
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    out.insert("error".into(), json!(message));
    out.insert("code".into(), json!(code));
    println!("{}", Value::Object(out));
    std::process::exit(1);
}
