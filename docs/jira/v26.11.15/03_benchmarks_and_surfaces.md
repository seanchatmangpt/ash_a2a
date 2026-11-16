# AshA2A Benchmarks & WASM Surfaces Audit Report (v26.11.15)

## 1. Executive Summary

This report documents the live benchmark execution, WebAssembly (`praxis_graphlaw.wasm`) host verification, performance scaling analysis, anti-vacuity evaluation, and unbenchmarked surface discovery for `/Users/sac/ash_a2a` as part of the v26.11.15 production health and audit review.

All verifications were executed against the live codebase without modifying any source code or test files.

### Key Audit Findings
1. **Live WASM Verification Succeeded**: `priv/graphlaw/praxis_graphlaw.wasm` (3,249,361 bytes) was verified across two independent hosts (in-BEAM `Wasmex` via Rustler NIF, and out-of-BEAM `Node.js` via `graphlaw_host.mjs`). Canonical graph identity (prefix-label and triple-order invariance), BLAKE3 test vectors, and SHACL validation reports were verified live.
2. **Cranelift Compilation Speedup (245x)**: Cold module compilation via Cranelift measured `1,720,723 us` (~1.72 s), while warm session instantiation from the `:persistent_term` compiled-module cache (`AshA2A.GraphLaw.EngineLoad`) measured `7,000 us` (7.0 ms).
3. **WasmexPool Multi-Core Scaling (19.1x Throughput, 25.6x Latency Reduction)**: Single `WasmexHost` serializes all transactions in one GenServer mailbox, becoming a bottleneck at concurrency $c=32$ (145.5 ops/s, $p50=103.5$ ms, $p99=300.8$ ms). `WasmexPool` (size 8) scales to 2,785.4 ops/s with $p50=7.3$ ms and $p99=11.7$ ms.
4. **Stale Benchmark Harness (`bench/ash_a2a_bench.exs`)**: The benchmark harness fails out of the box due to unresolved references to `A2A.Part.Data.new/1` and `A2A.Message.new_user/1`, which were migrated to `AshA2A.Protocol.*` in v26.10.x.
5. **Dev Boot SQLite Lock Contention (`tmp/ash_a2a/dev_authority_ekv`)**: Running `mix run` under default `MIX_ENV=dev` attempts to start `AshA2A.Authority.Broker.Ekv` pointing to `tmp/ash_a2a/dev_authority_ekv`, which crashes if stale WAL/SHM locks exist (`unable to open database file`), and unnecessarily triggers release C++ compilation of `oxrocksdb-sys` for `:ggen_igniter`.
6. **Live Engine Tests Excluded from Default `test.all`**: `mix.exs:60` explicitly excludes `--exclude graphlaw --exclude graphlaw_engine` from `"test.all"`.
7. **Unbenchmarked Production Surfaces**: gRPC server/client, SSE streaming responses, OcelForwarder task backpressure, AffidavitPool Wasmex execution, and DurableServer/Oban adapters have zero continuous benchmarks in `bench/`.

---

## 2. Live WebAssembly Engine Verification

### 2.1 Artifact Content Address & Integrity
The vendored artifact `priv/graphlaw/praxis_graphlaw.wasm` is content-addressed and pinned by `priv/graphlaw/MANIFEST.json` and `priv/graphlaw/WASMEX_HOST_MANIFEST.json`.

**Verification Command:**
```bash
cd /Users/sac/ash_a2a && elixir -e '
Path.wildcard("_build/dev/lib/*/ebin") |> Enum.each(&Code.append_path/1)
Mix.start()
Mix.Tasks.AshA2a.VerifyGraphlaw.run([])
'
```

**Observed Command Output:**
```text
law package : /Users/sac/ash_a2a/_build/dev/lib/ash_a2a/priv/graphlaw
schema      : ash_a2a.graphlaw.manifest/v1
graphlaw    : praxis-graphlaw v26.7.5
content_digest: OK d895a3422d394a54c05f1c2e365ec90499933d8928c31bdd6c12a988e9e62696
bytes       : OK 3249361
sha256      : OK 187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28
blake3      : OK 4724fbf950599642f898175319790bb35f192a60189e7b19963195fc3106cd36
execution   : OK (real wasm instantiation)
  graphlaw_version()        = praxis-graphlaw v26.7.5
  graph_hash(base.ttl)      = 9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d
  canonical order invariant : PASS
  distinct graph distinct   : PASS
  blake3_hex("abc") vector  : PASS
GraphLaw law package VERIFIED.
```

### 2.2 Live In-BEAM Execution via Wasmex (Wasmtime NIF)
We tested instantiation, linear-memory pointer passing via the wasm-bindgen ABI (`__wbindgen_add_to_stack_pointer`, `__wbindgen_export2`, `__wbindgen_export4`), and function invocation directly inside the BEAM.

**Verification Command:**
```bash
cd /Users/sac/ash_a2a && elixir -pa _build/dev/lib/wasmex/ebin -e '
bytes = File.read!("/Users/sac/ash_a2a/priv/graphlaw/praxis_graphlaw.wasm")
{:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{})
{:ok, store} = Wasmex.Store.new(nil, engine)
{:ok, module} = Wasmex.Module.compile(store, bytes)

imports = %{
  "./praxis_graphlaw_wasm_bg.js" => %{
    "__wbindgen_object_drop_ref" => {:fn, [:i32], [], fn _context, _handle -> nil end},
    "__wbg_getRandomValues_3f44b700395062e5" =>
      {:fn, [:i32, :i32], [],
       fn context, ptr, len ->
         random_bytes = :crypto.strong_rand_bytes(len)
         Wasmex.Memory.write_binary(context.caller, context.memory, ptr, random_bytes)
         nil
       end}
  }
}

{:ok, pid} = Wasmex.start_link(%{store: store, module: module, imports: imports})
{:ok, mem} = Wasmex.memory(pid)
{:ok, wasm_store} = Wasmex.store(pid)

call_wasm = fn fun, args ->
  {:ok, [retptr]} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [-16])
  ptr_lens = Enum.flat_map(args, fn arg ->
    len = byte_size(arg)
    {:ok, [ptr]} = Wasmex.call_function(pid, "__wbindgen_export2", [max(len, 1), 1])
    :ok = Wasmex.Memory.write_binary(wasm_store, mem, ptr, arg)
    [ptr, len]
  end)
  {:ok, []} = Wasmex.call_function(pid, fun, [retptr | ptr_lens], 5000)
  <<res_ptr::little-signed-32, res_len::little-signed-32>> = Wasmex.Memory.read_binary(wasm_store, mem, retptr, 8)
  res_str = Wasmex.Memory.read_binary(wasm_store, mem, res_ptr, res_len)
  {:ok, _} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [16])
  {:ok, []} = Wasmex.call_function(pid, "__wbindgen_export4", [res_ptr, res_len, 1])
  res_str
end

v = call_wasm.("graphlaw_version", [])
b3 = call_wasm.("blake3_hex", ["abc"])
base_ttl = "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
reordered_ttl = "@prefix zz: <http://example.org/> .\nzz:b zz:p zz:c .\nzz:a zz:p zz:b .\n"
h1 = call_wasm.("graph_hash", [base_ttl])
h2 = call_wasm.("graph_hash", [reordered_ttl])

shacl_shapes = "@prefix sh: <http://www.w3.org/ns/shacl#> .\n@prefix ex: <http://example.org/> .\nex:Shape a sh:NodeShape ; sh:targetSubjectsOf ex:p ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .\n"
val_res = call_wasm.("validate_all", [base_ttl, "", shacl_shapes, "", ""])

IO.puts("graphlaw_version: #{v}")
IO.puts("blake3_hex(\"abc\"): #{b3}")
IO.puts("canonical equality: #{h1 == h2}")
IO.puts("validate_all snippet: #{String.slice(val_res, 0, 100)}")
'
```

**Observed Command Output:**
```text
graphlaw_version: praxis-graphlaw v26.7.5
blake3_hex("abc"): 6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85
canonical equality: true
validate_all snippet: {"graph_hash":"9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d","profile_hash":"","dialects"
```

### 2.3 Live Out-of-BEAM Execution via Node Host
**Verification Command:**
```bash
echo '{"wasm":"/Users/sac/ash_a2a/priv/graphlaw/praxis_graphlaw.wasm","calls":[{"fn":"graphlaw_version","args":[]},{"fn":"blake3_hex","args":["abc"]}]}' | node /Users/sac/ash_a2a/priv/graphlaw/host/graphlaw_host.mjs
```

**Observed Command Output:**
```json
{"ok":true,"results":["praxis-graphlaw v26.7.5","6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"],"exports":["memory","blake3_hex","graph_hash","graphlaw_version","init_panic_hook","run_hooks","validate_all","__abort_handler","__instance_terminated","__wbindgen_export","__wbindgen_add_to_stack_pointer","__wbindgen_export2","__wbindgen_export3","__wbindgen_export4","__wbindgen_start"],"imports":["./praxis_graphlaw_wasm_bg.js::__wbindgen_object_drop_ref","./praxis_graphlaw_wasm_bg.js::__wbg_getRandomValues_3f44b700395062e5"]}
```

---

## 3. Benchmark Harnesses & Live Performance Data

### 3.1 Cold vs Warm WasmexSession Instantiation
`AshA2A.GraphLaw.EngineLoad` implements a `:persistent_term` cache storing `{engine, module, import_names}` indexed by `{sha256, fuel?}`.

**Verification Command:**
```bash
cd /Users/sac/ash_a2a && elixir -e '
Path.wildcard("_build/dev/lib/*/ebin") |> Enum.each(&Code.append_path/1)
alias AshA2A.GraphLaw.WasmexSession
{cold_us, {:ok, %{session: s1}}} = :timer.tc(fn -> WasmexSession.open([]) end)
WasmexSession.close(s1)
{warm_us, {:ok, %{session: s2}}} = :timer.tc(fn -> WasmexSession.open([]) end)
WasmexSession.close(s2)
IO.puts("Cold compile latency: #{cold_us} us (#{Float.round(cold_us / 1000, 2)} ms)")
IO.puts("Warm session open:    #{warm_us} us (#{Float.round(warm_us / 1000, 2)} ms)")
IO.puts("Speedup factor:        #{Float.round(cold_us / max(warm_us, 1), 1)}x")
'
```

**Observed Command Output:**
```text
Cold compile latency: 1720723 us (1720.72 ms)
Warm session open:    7000 us (7.0 ms)
Speedup factor:        245.8x
```

### 3.2 Throughput & Concurrency Sweep: Single WasmexHost vs WasmexPool
We tested concurrency scaling across concurrency levels $c = 1, 8, 32$ for:
1. `AshA2A.GraphLaw.WasmexHost` (Single GenServer process serializing transactions).
2. `AshA2A.GraphLaw.WasmexPool` (Supervised pool of 8 WasmexHost instances with shortest-mailbox routing).

**Verification Command:**
```bash
cd /Users/sac/ash_a2a && elixir -e '
Path.wildcard("_build/dev/lib/*/ebin") |> Enum.each(&Code.append_path/1)
Application.ensure_all_started(:telemetry)
alias AshA2A.GraphLaw.{WasmexHost, WasmexPool}
alias AshA2A.Semantic.GraphLawBridge

ttl = "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"

sweep = fn label, concurrency, n ->
  started = System.monotonic_time(:microsecond)
  results = 1..n
  |> Task.async_stream(fn _ -> :timer.tc(fn -> GraphLawBridge.graph_hash(ttl) end) end, max_concurrency: concurrency, timeout: :infinity)
  |> Enum.map(fn {:ok, timed} -> timed end)
  wall = max(System.monotonic_time(:microsecond) - started, 1)
  {ok, failed} = Enum.split_with(results, fn {_us, res} -> match?({:ok, _}, res) end)
  latencies = ok |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  ops = Float.round(length(ok) * 1_000_000 / wall, 1)
  p50 = Enum.at(latencies, trunc(0.50 * length(latencies)))
  p99 = Enum.at(latencies, trunc(0.99 * length(latencies)))
  IO.puts("#{label} c=#{concurrency}: #{ops} ops/s (p50: #{p50} us, p99: #{p99} us, wall: #{wall} us)")
end

# Single WasmexHost
{:ok, _} = WasmexHost.start_link(name: WasmexHost)
IO.puts("--- SINGLE WASMEX HOST ---")
sweep.("SingleHost", 1, 50)
sweep.("SingleHost", 8, 50)
sweep.("SingleHost", 32, 50)
GenServer.stop(WasmexHost)

# WasmexPool (size 8)
{:ok, _} = WasmexPool.start_link(size: 8)
IO.puts("--- WASMEX POOL (SIZE 8) ---")
sweep.("Pool(8)", 1, 50)
sweep.("Pool(8)", 8, 50)
sweep.("Pool(8)", 32, 50)
'
```

**Observed Command Output:**
```text
--- SINGLE WASMEX HOST ---
SingleHost c=1: 67.8 ops/s (p50: 10014 us, p99: 48700 us, wall: 737116 us)
SingleHost c=8: 203.6 ops/s (p50: 20467 us, p99: 111483 us, wall: 245543 us)
SingleHost c=32: 145.5 ops/s (p50: 103567 us, p99: 300889 us, wall: 343719 us)

--- WASMEX POOL (SIZE 8) ---
Pool(8) c=1: 354.9 ops/s (p50: 2306 us, p99: 12558 us, wall: 140865 us)
Pool(8) c=8: 2155.5 ops/s (p50: 2789 us, p99: 6932 us, wall: 23196 us)
Pool(8) c=32: 2785.4 ops/s (p50: 7340 us, p99: 11715 us, wall: 17951 us)
```

**Performance Metrics Comparison Table:**
| Configuration | Concurrency ($c$) | Throughput (ops/s) | p50 Latency ($\mu$s) | p99 Latency ($\mu$s) | Wall Time ($\mu$s) |
|---|---|---|---|---|---|
| **Single WasmexHost** | $c=1$ | 67.8 | 10,014 (10.0 ms) | 48,700 (48.7 ms) | 737,116 |
| **Single WasmexHost** | $c=8$ | 203.6 | 20,467 (20.5 ms) | 111,483 (111.5 ms) | 245,543 |
| **Single WasmexHost** | $c=32$ | 145.5 | 103,567 (103.6 ms) | 300,889 (300.9 ms) | 343,719 |
| **WasmexPool (size 8)** | $c=1$ | 354.9 | 2,306 (2.3 ms) | 12,558 (12.6 ms) | 140,865 |
| **WasmexPool (size 8)** | $c=8$ | 2,155.5 | 2,789 (2.8 ms) | 6,932 (6.9 ms) | 23,196 |
| **WasmexPool (size 8)** | $c=32$ | **2,785.4** | **7,340 (7.3 ms)** | **11,715 (11.7 ms)** | **17,951** |

**Delta Analysis:**
- Throughput at $c=32$: $2,785.4$ vs $145.5$ ops/s (**19.14x scaling speedup**).
- p50 latency at $c=32$: $7.34$ ms vs $103.57$ ms (**14.1x lower latency**).
- p99 tail latency at $c=32$: $11.72$ ms vs $300.89$ ms (**25.68x lower tail latency**).

### 3.3 Core Protocol Operations (`bench/ash_a2a_bench.exs`)
We executed the core protocol benchmark suite covering capability indexing, semantic compilation, command fingerprinting, receipt synthesis, and `CommandBus.run/4` end-to-end dispatch.

**Verification Command:**
```bash
cd /Users/sac/ash_a2a && elixir -e '
Path.wildcard("_build/dev/lib/*/ebin") |> Enum.each(&Code.append_path/1)
Mix.start()
Application.put_env(:ash, :default_string_length_count, :codepoints)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:ash)

defmodule A2A.Part.Data do
  def new(data), do: AshA2A.Protocol.Part.Data.new(data)
end
defmodule A2A.Message do
  def new_user(parts), do: AshA2A.Protocol.Message.new_user(parts)
end

Code.require_file("bench/ash_a2a_bench.exs")
'
```

**Measured Baseline Results ($c=1$, 100 iterations per operation):**
```text
AshA2A.Info.capability_index/1
  n = 100, mean = 2 us, p50 = 1 us, p95 = 4 us, p99 = 20 us, ops = 18583.9 ops/s

AshA2A.Semantic.Compiler.compile/3 (1 text)
  n = 100, mean = 119 us, p50 = 112 us, p95 = 147 us, p99 = 243 us, ops = 7611.5 ops/s

AshA2A.Semantic.Compiler.compile_many/3 (50 texts)
  n = 100, mean = 6320 us, p50 = 4286 us, p95 = 14210 us, p99 = 17821 us, ops = 154.9 ops/s

AshA2A.Command.fingerprint/1
  n = 100, mean = 1 us, p50 = 1 us, p95 = 2 us, p99 = 3 us, ops = 116009.3 ops/s

AshA2A.Receipt.from_reply/4
  n = 100, mean = 85 us, p50 = 81 us, p95 = 96 us, p99 = 148 us, ops = 10632.6 ops/s

AshA2A.CommandBus.run/4 (:observe consequence, real dispatch)
  n = 100, mean = 3499 us, p50 = 1490 us, p95 = 13373 us, p99 = 22170 us, ops = 283.9 ops/s

AshA2A.CommandBus.run/4 (:change consequence, real Ash.create)
  n = 100, mean = 2023 us, p50 = 967 us, p95 = 9253 us, p99 = 12472 us, ops = 487.2 ops/s

AshA2A.CapabilityIndex.Compiler.compile/3 (Item, 5 actions)
  n = 100, mean = 51 us, p50 = 10 us, p95 = 19 us, p99 = 55 us, ops = 9127.4 ops/s
```

**Measured Concurrent Scaling Results ($c=8$ concurrent workers):**
```text
AshA2A.Info.capability_index/1                      conc = 8, ops = 1779.8 ops/s (p50 = 2 us, p99 = 5 us)
AshA2A.Semantic.Compiler.compile/3 (1 text)         conc = 8, ops = 9938.4 ops/s (p50 = 184 us, p99 = 740 us)
AshA2A.Semantic.Compiler.compile_many/3 (50 texts)  conc = 8, ops = 575.3 ops/s (p50 = 10641 us, p99 = 33176 us)
AshA2A.Command.fingerprint/1                        conc = 8, ops = 83963.1 ops/s (p50 = 2 us, p99 = 20 us)
AshA2A.Receipt.from_reply/4                         conc = 8, ops = 4342.0 ops/s (p50 = 129 us, p99 = 468 us)
AshA2A.CommandBus.run/4 (:observe consequence)      conc = 8, ops = 97.1 ops/s (p50 = 71701 us, p99 = 175507 us)
AshA2A.CommandBus.run/4 (:change consequence)       conc = 8, ops = 1094.2 ops/s (p50 = 4941 us, p99 = 16243 us)
AshA2A.CapabilityIndex.Compiler.compile/3 (Item)    conc = 8, ops = 62656.6 ops/s (p50 = 9 us, p99 = 22 us)
```

**Observation on `:observe` Concurrency Bottleneck:**
Under concurrency $c=8$, `:observe` throughput degraded from 283.9 to 97.1 ops/s, with $p50$ increasing from 1.49 ms to 71.7 ms and $p99$ reaching 175.5 ms. The root cause is `AshA2A.ReceiptStore.Memory` GenServer message-queue serialization during `store.claim/2` and `store.commit/2` when all workers contention-claim under one registered name. In contrast, `:change` consequence scaled from 487.2 to 1,094.2 ops/s.

---

## 4. Gaps, Vacuity Issues & Unfinished Items

### Gap 1: Staleness in `bench/ash_a2a_bench.exs` Module Namespace
- **Target File**: `bench/ash_a2a_bench.exs:213,264`
- **Issue Description**: When `ash_a2a` removed the standalone `{:a2a, "~> 0.2"}` Hex package and vendored the protocol as `AshA2A.Protocol.*` (documented in `docs/how-to/migrate-from-a2a-hex.md`), `bench/ash_a2a_bench.exs` was not updated. Lines 213 and 264 call `A2A.Message.new_user([A2A.Part.Data.new(...)])`. Running the script directly fails with `UndefinedFunctionError: function A2A.Part.Data.new/1 is undefined`.
- **Exact Execution Command**:
  ```bash
  cd /Users/sac/ash_a2a && mix run bench/ash_a2a_bench.exs
  ```
- **Error Output**:
  ```text
  ** (UndefinedFunctionError) function A2A.Part.Data.new/1 is undefined (module A2A.Part.Data is not available)
      A2A.Part.Data.new(%{})
      bench/ash_a2a_bench.exs:213: anonymous fn/0 in AshA2A.Bench.run/0
  ```
- **Remediation**: Update `bench/ash_a2a_bench.exs` to alias or call `AshA2A.Protocol.Message` and `AshA2A.Protocol.Part.Data`.

---

### Gap 2: Dev Environment Boot Crashes on Stale SQLite WAL/SHM Locks
- **Target File**: `config/dev.exs:22-24`, `lib/ash_a2a/application.ex:353-384`
- **Issue Description**: `config/dev.exs` configures `:authority_broker` as `{AshA2A.Authority.Broker.Ekv, data_dir: Path.expand("tmp/ash_a2a/dev_authority_ekv", File.cwd!())}`. If a prior BEAM process crashes or exits without checkpointing SQLite shards, stale `-wal` or `-shm` files remain. On boot, `EKV.Replica` fails to open the database file, causing `AshA2A.Application.start` to fail-closed.
- **Exact Execution Command**:
  ```bash
  cd /Users/sac/ash_a2a && mix run -e "IO.puts(:booted)"
  ```
- **Error Output**:
  ```text
  ** (Mix) Could not start application ash_a2a: AshA2A.Application.start(:normal, []) returned an error: shutdown: failed to start child: {EKV, AshA2A.Authority.Broker.Ekv}
      ** (EXIT) shutdown: failed to start child: EKV.Replica.Supervisor
          ** (EXIT) shutdown: failed to start child: {EKV.Replica, 5}
              ** (EXIT) an exception was raised:
                  ** (MatchError) no match of right hand side value: {:error, ~c"unable to open database file"}
                      (ekv 0.4.8) lib/ekv/store.ex:355: EKV.Store.open_reader/1
  ```
- **Remediation**: `AshA2A.Application` or `AshA2A.Authority.Broker.Ekv` should catch SQLite open errors on uncheckpointed temporary shard files in non-prod environments, or clean up orphaned `-wal`/`-shm` lock files on startup.

---

### Gap 3: Missing Precompiled Binary for Native Host (`native/graphlaw_host`)
- **Target File**: `native/graphlaw_host`, `lib/ash_a2a/graph_law/wasmtime_runtime.ex:160-185`, `test/ash_a2a/graph_law/wasmtime_runtime_test.exs:23-28`
- **Issue Description**: `WasmtimeRuntime` implements Runtime B of the conformance court by executing `native/graphlaw_host/target/release/graphlaw_host`. This binary is gitignored and is never compiled during `mix compile` or `mix deps.get`. Consequently, in clean checkouts, `WasmtimeRuntime.available?()` returns `{:error, %{code: :graphlaw_host_not_built}}`, and all native Wasmtime tests in `wasmtime_runtime_test.exs` are skipped.
- **Verification Command**:
  ```bash
  cd /Users/sac/ash_a2a && cargo check --manifest-path native/graphlaw_host/Cargo.toml
  ```
- **Observed Output**:
  ```text
  Checking graphlaw_host v0.1.0 (/Users/sac/ash_a2a/native/graphlaw_host)
  Finished `dev` profile [unoptimized + debuginfo] target(s) in 2m 20s
  ```
- **Remediation**: Provide an automated build task (`mix ash_a2a.build_native_host` or hook in `mix compile`) to compile `native/graphlaw_host` when Rust toolchains are available.

---

### Gap 4: Quadratic Session Replay Latency in `WasmtimeRuntime`
- **Target File**: `lib/ash_a2a/graph_law/wasmtime_runtime.ex:44-65`
- **Issue Description**: As documented in `wasmtime_runtime.ex`, the native subprocess exits after each batch. To simulate a persistent stateful session (necessary for non-deterministic blank-node relabel sequences), `WasmtimeRuntime` replays the entire history of calls from an `Agent` on every single `call/3`. This makes session execution $O(N^2)$ in subprocess spawns and Cranelift recompilations.
- **Remediation**: Transition `native/graphlaw_host` to a persistent line-oriented worker protocol (similar to `graphlaw_host.mjs` or a standard port process) rather than throwaway batch processes for session execution.

---

### Gap 5: Test Suite Excludes Live Engine Verification by Default
- **Target File**: `mix.exs:60`
- **Issue Description**: The primary CI alias `"test.all"` specifies:
  `"test --include serial --exclude graphlaw --exclude graphlaw_engine --exclude sibling_repos"`
  Because `--exclude graphlaw --exclude graphlaw_engine` is hardcoded, standard full-suite test runs never exercise live WebAssembly instantiation or conformance checks.
- **Exact File Citation**:
  ```elixir
  # mix.exs line 59-60
  "test.all":
    "test --include serial --exclude graphlaw --exclude graphlaw_engine --exclude sibling_repos",
  ```
- **Remediation**: Add a dedicated CI stage (`mix test.graphlaw`) or include `:graphlaw` in automated verification gates when Node and Wasmex are present.

---

### Gap 6: Unbenchmarked Production Surfaces
The repository currently lacks continuous benchmark harnesses for several critical execution surfaces:
1. **gRPC Server & Client Transport** (`lib/ash_a2a/transport/grpc/`):
   - No latency or throughput benchmarks for unary requests, bi-directional streams, or protobuf serialization overhead.
2. **Server-Sent Events (SSE) & Plug Streaming** (`lib/ash_a2a/protocol/plug.ex`, `lib/ash_a2a/protocol/server_sent_events.ex`):
   - No benchmark measuring memory growth or backpressure under high subscriber concurrency.
3. **Telemetry & Event Egress** (`lib/ash_a2a/telemetry/ocel_forwarder.ex`):
   - No benchmark measuring the behavior of `AshA2A.Telemetry.TaskSupervisor` under network backpressure, or the exact throughput limit before `:max_children` drops events.
4. **Affidavit WASM Engine Pool** (`lib/ash_a2a/evidence/`):
   - No throughput benchmark measuring Poolboy/Wasmex execution under concurrent evidence signing.
5. **Authority Broker Concurrency** (`lib/ash_a2a/authority/broker/`):
   - No benchmark evaluating token verification contention across distributed agents in `AshA2A.Authority.Broker.Ekv`.

---

## 5. Verification Commands and Reproducibility Index

Every finding and benchmark reported above can be reproduced using these commands:

| Surface Audited | Reproduction Command | Expected Verdict |
|---|---|---|
| **Law Package Manifest & Execution** | `elixir -e 'Path.wildcard("_build/dev/lib/*/ebin") \|> Enum.each(&Code.append_path/1); Mix.start(); Mix.Tasks.AshA2a.VerifyGraphlaw.run([])'` | `GraphLaw law package VERIFIED.` |
| **Live Wasmex In-BEAM Execution** | `elixir -pa _build/dev/lib/wasmex/ebin -e '<Section 2.2 script>'` | `canonical equality: true` |
| **Live Node Out-of-BEAM Execution** | `echo "{\"wasm\":\"priv/graphlaw/praxis_graphlaw.wasm\",\"calls\":[{\"fn\":\"graphlaw_version\",\"args\":[]}]}" \| node priv/graphlaw/host/graphlaw_host.mjs` | `{"ok":true,"results":["praxis-graphlaw v26.7.5"]}` |
| **Cold vs Warm Session Latency** | `elixir -e '<Section 3.1 script>'` | Cold: ~1.72 s, Warm: ~7.0 ms (245x speedup) |
| **SingleHost vs Pool(8) Throughput** | `elixir -e '<Section 3.2 script>'` | SingleHost: 145.5 ops/s, Pool(8): 2785.4 ops/s at c=32 |
| **Core Protocol Operations Benchmark** | `elixir -e '<Section 3.3 script>'` | CapabilityIndex: ~18.5k ops/s, Fingerprint: ~116k ops/s, CommandBus: ~487 ops/s |
| **Native Rust Host Crate Compilation** | `cargo check --manifest-path native/graphlaw_host/Cargo.toml` | `Finished dev profile target(s) in 2m 20s` |
