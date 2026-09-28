defmodule AshA2A.GraphLaw.WasmexHost do
  @moduledoc """
  Real Elixir host for the `praxis-graphlaw` WebAssembly law package.

  RFC-SA2A-001 v26.9.16 S12 (canonical graph identity), S79 (standard
  technology baseline), S27 (projection).

  ## What this module is, and what it deliberately is not

  This repository does **not** own — and must never grow — its own RDF
  canonicalization, SHACL, ShEx, Datalog, N3 or SPARQL implementation.
  `praxis-graphlaw` already is one (`praxis-graphlaw v26.7.9` self-describes
  as "law-state engine: native N3, Datalog, SPARQL 1.1, SHACL, ShEx", built
  over `oxrdf` with the `rdfc-10` feature, and `blake3`). The engine's real
  RDFC-1.0 (`oxrdf` `Rdfc10`) is **not** wired to any wasm export: the
  `graph_hash` export this module calls is prefix- and triple-order-invariant
  but not blank-node-relabel invariant, so it is not RDFC-1.0. RFC S12
  canonical graph identity is `AshA2A.Semantic.CanonicalGraph` (RDFC-1.0 via
  the RDF.ex dependency, in-BEAM); see
  `docs/explanation/canonical-graph-identity.md`.

  The engine is compiled to a single content-addressed WebAssembly artifact,
  vendored at `priv/graphlaw/praxis_graphlaw.wasm` (resolved through
  `AshA2A.GraphLaw.wasm_path/0`, the one canonical vendored copy that
  `mix ash_a2a.vendor_graphlaw` writes and `mix ash_a2a.verify_graphlaw`
  verifies against `priv/graphlaw/MANIFEST.json`). This host's own measured
  record of those bytes lives in `priv/graphlaw/WASMEX_HOST_MANIFEST.json`.

  Elixir's job at this boundary is envelope, standing, refusal typing,
  authority, receipts, admission orchestration and the A2A boundary —
  never the derivation itself. That split is the whole point: the *same*
  wasm bytes can be executed by a different host runtime (this module uses
  Wasmtime via `wasmex`; the reference measurement used V8 under Node),
  which is precisely the substitution the "SA2A Portable Semantic Execution
  Conformance" claim is about.

  ## Relation to the other GraphLaw hosts in this repository

  Three independent hosts execute the same wasm bytes, and each keeps its
  own contract:

    * `AshA2A.GraphLaw.Wasm` -- the `node` subprocess host (one process and
      one instantiation per `batch/2`), used by the admission pipeline and
      probed by `AshA2A.Semantic.GraphLawBridge`.
    * `AshA2A.GraphLaw.WasmexSession` -- the conformance court's runtime A:
      caller-owned `open/1`/`call/3`/`close/1` sessions with a deterministic
      `getRandomValues` import.
    * this module -- one long-lived, application-supervised Wasmtime
      instance with whole-transaction serialization, real entropy, a
      non-UTF-8 guard, and `memory_size/2` for verifying that guard.

  ## NO AUTHORITY (RFC S4.4 / S17)

  **GraphLaw derives and validates; it never authorizes and never
  actuates.** `GraphLaw != Authority != DO.` Nothing in this module grants,
  checks, or carries authority, and nothing here performs a consequential
  action. A `{:ok, _}` from `validate_all/5` or `run_hooks/2` is *evidence*
  offered to an admission decision — it is not an admission, not a grant,
  and not a receipt. Every real consequence still funnels through
  `AshA2A.CommandBus` with a real `AshA2A.Authority` grant, exactly as it
  did before this module existed.

  ## Determinism is a property to be TESTED, not assumed

  The wasm module imports a `getRandomValues` host function, and this host
  satisfies it with real entropy (`:crypto.strong_rand_bytes/1`). The
  engine therefore *may* consume randomness. Every digest this module has
  actually been observed to produce is stable and host-independent (see
  `test/ash_a2a/graph_law_wasmex_host_test.exs`, which asserts digests measured
  independently under a different host runtime), but that is a **measured
  fact about the functions exercised so far, not a guarantee about the
  engine as a whole**. A conformance suite must keep re-measuring it rather
  than assume it. Supplying a deterministic stub instead would hide exactly
  the property the court exists to test, so this host does not do that.

  ## Measured leniency of `graph_hash/1` (do not mistake it for validation)

  Confirmed against this exact artifact, and confirmed in
  `praxis-graphlaw-wasm/src/core.rs`: `graph_hash_core_impl/1` preprocesses
  the Turtle, builds a triple store, and hashes the canonical content —
  there is **no fallible parse step**. The only `Err` it can return is
  `"Engine panic in graph_hash_core"` from its own `catch_unwind`.
  Malformed Turtle therefore does **not** produce an error: it silently
  degrades to whatever subset parsed, up to and including the empty graph
  (`graph_hash("")` and `graph_hash("@prefix ex: <http://e/> .\\nex:a ex:p")`
  both return BLAKE3's published empty-input digest
  `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`).

  `graph_hash/1` is an identity function, not an admission gate. Syntactic
  refusal belongs to `validate_all/5`, which *does* report real per-dialect
  `"REFUSED"` verdicts with real parser diagnostics.

  ## Error contract

  The engine returns `{"error": "..."}` **as a value** rather than trapping
  (its own source comments the reason: wasm/JS error marshaling is
  comparatively expensive). Callers must check for the `"error"` key, and
  this module does — mapping it to
  `{:error, %{code: :graphlaw_error, detail: ...}}`. No public function in
  this module raises on an engine error.

  ## Instance lifecycle and concurrency

  A Wasmex instance is not free to create (a 3.2 MB module compiled by
  Wasmtime), so one is created once and reused. It is held by **this**
  module's own supervised `GenServer`, wired into `AshA2A.Application`.

  The outer GenServer is load-bearing, not decoration. `Wasmex`'s own
  GenServer serializes *individual* calls, but a single wasm-bindgen
  string-returning call is a **multi-step transaction** against shared
  instance state:

      __wbindgen_add_to_stack_pointer(-16)   # claim a 16-byte return slot
      __wbindgen_export2(len, 1)             # malloc each argument
      Memory.write_binary(...)               # copy argument bytes in
      fn(retptr, ptr0, len0, ...)            # the real call
      Memory.read_binary(retptr, 8)          # read (ptr, len) result pair
      __wbindgen_add_to_stack_pointer(+16)   # release the return slot
      __wbindgen_export4(ptr, len, 1)        # free the returned string

  Two BEAM processes interleaving those steps against one instance would
  corrupt the shadow stack and read each other's return slots. Serializing
  the *whole transaction* inside `handle_call/3` is what makes this module
  safe to share across concurrent BEAM processes. It is safe to call from
  any number of processes; calls are serialized, so it is a throughput
  bottleneck by construction, and a host that needs parallelism should run
  several named instances rather than share one.

  Every transaction restores the stack pointer and frees the returned
  string in an `after` block, so a raise or a wasm trap cannot leak either.

  ## Bounds, recycling and pooling (PERF-02/04/05/06, SC-04)

    * **Digest pin.** `init/1` loads through `AshA2A.GraphLaw.EngineLoad.load/3`
      with the MANIFEST pin (`EngineLoad.pinned_sha256/0`, or
      `opts[:expected_sha256]`, or `config :ash_a2a, :graphlaw_wasm_sha256`).
      Swapped or corrupted bytes leave the host `{:unavailable,
      %{code: :graphlaw_wasm_digest_mismatch}}`. `expected_sha256: :unpinned`
      is the explicit opt-out.
    * **Shared compile.** The compiled module comes from EngineLoad's
      per-node cache, so a restart or an in-process recycle costs one
      instantiation, not a Cranelift compile.
    * **Fuel + memory limit.** The store is built on a fuel-metering engine
      with `%Wasmex.StoreLimits{memory_size: ...}`
      (`:graphlaw_memory_limit_bytes`, default 256 MiB) and every transaction
      starts with a fresh fuel budget (`:graphlaw_fuel_per_call`, default
      10,000,000,000 instructions). The default wall-clock bound is 5 s.
    * **Exits never kill the host.** Each raw wasm call is a direct
      `GenServer.call` to the Wasmex instance with a caller deadline 1 s
      beyond the native interrupt deadline, and any exit is caught and typed
      (`:graphlaw_call_exited`). The host traps exits of its instance.
    * **Recycling.** After a failed transaction (trap, exit, ABI failure) or
      when linear memory exceeds the high-water mark
      (`:graphlaw_memory_recycle_bytes`, default 128 MiB -- linear memory never
      shrinks), the instance is replaced in-process from the cached module;
      the queued mailbox survives. Telemetry:
      `[:ash_a2a, :graphlaw, :host, :recycle]`.
    * **Load shedding.** A call whose target mailbox already holds
      `:graphlaw_max_queue` (default 64) messages is refused
      `{:error, %{code: :graphlaw_saturated}}` instead of queueing unbounded.
    * **Pool.** `AshA2A.GraphLaw.WasmexPool` runs N of these hosts; calls to
      the default server name are routed to the least-loaded pool member when
      a pool is running.

  ## Missing artifact

  Following `AshA2A.Planning.HddlSolver`'s convention for an absent native
  binary, an absent `.wasm` is a typed error, never a crash: the GenServer
  still starts (so the supervision tree is unaffected) and every call
  returns `{:error, %{code: :graphlaw_wasm_not_vendored, ...}}`.

  ## Non-UTF-8 input is refused BEFORE the engine, not after

  Every public function below that takes a string argument marshals it into
  the vendored `praxis-graphlaw` engine's Rust `&str` export. A single
  invalid UTF-8 byte is not a recoverable condition on that boundary: it was
  measured (real repro, `AshA2A.GraphLaw.WasmexHost.graph_hash(<<0xFF>>)`) to
  commit 2,148,270,080 bytes of linear memory in ONE call and permanently
  poison the instance -- a second call on the poisoned instance committed a
  further 1,073,807,360 bytes. That is a real, reproducible denial-of-service
  on any input path that reaches this module with untrusted bytes.

  `ensure_utf8/1` guards every such argument up front and returns a typed
  `{:error, {:invalid_encoding, byte_offset}}` without ever reaching
  `transact/4`. `ensure_utf8/1` delegates to
  `AshA2A.Semantic.CanonicalGraph.ensure_utf8/1`, so the encoding guard and its
  typed contract have exactly one implementation in this repository -- the
  guard `docs/explanation/canonical-graph-identity.md` specified for this wasm
  string boundary.
  """

  use GenServer

  alias AshA2A.GraphLaw.EngineLoad

  require Logger

  @import_namespace "./praxis_graphlaw_wasm_bg.js"
  @default_timeout 5_000
  # Per-step bound for the wasm-bindgen ABI helper calls (stack pointer,
  # malloc, free): each is a handful of instructions.
  @abi_timeout 1_000
  @default_fuel 10_000_000_000
  @instantiate_fuel 1_000_000_000
  @default_memory_limit 256 * 1024 * 1024
  @default_recycle_bytes 128 * 1024 * 1024
  @default_max_queue 64

  @doc false
  # RFC-SA2A-001 S42 classes for the typed transport codes this host returns.
  def __sa2a_refusal_codes__,
    do: %{
      graphlaw_call_exited: :blocked_resource,
      graphlaw_saturated: :blocked_resource,
      graphlaw_timeout: :blocked_resource,
      graphlaw_not_started: :blocked_resource,
      graphlaw_instantiation_failed: :blocked_resource,
      graphlaw_wasm_unreadable: :blocked_resource,
      graphlaw_wasm_not_vendored: :blocked_resource,
      graphlaw_unknown_function: :blocked_resource
    }

  # wasm-bindgen's shadow-stack return slot is 16 bytes; a String return is
  # the first two little-endian i32 in it: (ptr, len).
  @ret_slot 16
  @ret_header 8

  @typedoc "Every error this module returns carries a `:code`."
  @type error :: %{required(:code) => atom(), optional(atom()) => term()}

  @typedoc """
  The encoding-guard error: the input is not valid UTF-8. `byte_offset` is
  the index of the first invalid byte.
  """
  @type encoding_error :: {:invalid_encoding, non_neg_integer()}

  # ---------------------------------------------------------------------
  # Artifact resolution
  # ---------------------------------------------------------------------

  @doc """
  Resolves the real vendored `.wasm` path: `opts[:wasm_path]`, else
  `config :ash_a2a, :graphlaw_wasm_path`, else the canonical vendored
  artifact `AshA2A.GraphLaw.wasm_path/0` (`priv/graphlaw/praxis_graphlaw.wasm`
  inside this application's real `priv` directory). Defaulting to that one
  canonical copy -- rather than a second, byte-identical file under another
  name -- means a re-vendor through `mix ash_a2a.vendor_graphlaw` cannot
  leave this host executing stale bytes that `mix ash_a2a.verify_graphlaw`
  never checks.

  Unlike `AshA2A.Planning.HddlSolver.cli_path/1` (whose `native/` tree is
  excluded from the published package), `priv` **is** shipped — see
  `mix.exs`'s `package: [files: ...]` — so the default resolves correctly
  inside an installed hex dependency as well as in a source checkout.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      AshA2A.GraphLaw.wasm_path()
  end

  @manifest_file "WASMEX_HOST_MANIFEST.json"

  @doc """
  Reads this host's real `priv/graphlaw/WASMEX_HOST_MANIFEST.json` artifact
  record (next to the resolved `.wasm`).

  This is the honest per-host artifact record; the package-level
  `priv/graphlaw/MANIFEST.json` (schema `ash_a2a.graphlaw.manifest/v1`) is
  owned by `AshA2A.GraphLaw.Manifest` and is not read here. This function
  only surfaces what was actually measured about the bytes on disk.
  """
  @spec manifest(keyword()) :: {:ok, map()} | {:error, error()}
  def manifest(opts \\ []) do
    path =
      Keyword.get(opts, :manifest_path) ||
        Path.join(Path.dirname(wasm_path(opts)), @manifest_file)

    with {:ok, raw} <- read_manifest(path),
         {:ok, decoded} <- decode_manifest(raw, path) do
      {:ok, decoded}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, raw}

      {:error, reason} ->
        {:error, %{code: :graphlaw_manifest_unreadable, path: path, reason: reason}}
    end
  end

  defp decode_manifest(raw, path) do
    case JSON.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, %{code: :non_json_manifest, path: path, reason: reason}}
    end
  end

  # ---------------------------------------------------------------------
  # Public API -- every function returns ok/error, none raise on engine error
  # ---------------------------------------------------------------------

  @doc """
  Returns the engine's own self-reported version string, e.g.
  `{:ok, "praxis-graphlaw v26.7.5"}`.

  This is the version of the *vendored wasm artifact*, which may lag the
  version of the `praxis-graphlaw` crate it was built from — report this
  value, never the crate's.
  """
  @spec version(GenServer.server(), timeout()) :: {:ok, String.t()} | {:error, error()}
  def version(server \\ __MODULE__, timeout \\ @default_timeout) do
    with {:ok, raw} <- transact(server, "graphlaw_version", [], timeout) do
      as_plain_string(raw)
    end
  end

  @doc """
  Canonical graph identity (RFC S12): the BLAKE3 hex digest of the graph's
  canonical N-Quads form.

  Invariant under prefix labelling and triple order; distinct for a
  distinct graph. See the module doc's leniency note — this does **not**
  validate the input.
  """
  @spec graph_hash(String.t(), GenServer.server(), timeout()) ::
          {:ok, String.t()} | {:error, error()} | {:error, encoding_error()}
  def graph_hash(ttl, server \\ __MODULE__, timeout \\ @default_timeout) when is_binary(ttl) do
    with :ok <- ensure_utf8(ttl),
         {:ok, raw} <- transact(server, "graph_hash", [ttl], timeout) do
      as_plain_string(raw)
    end
  end

  @doc """
  Real BLAKE3 hex digest of arbitrary UTF-8 bytes, computed by the engine
  itself (not by a separate Elixir implementation), so receipts stay on one
  hash algorithm end to end.
  """
  @spec blake3_hex(String.t(), GenServer.server(), timeout()) ::
          {:ok, String.t()} | {:error, error()} | {:error, encoding_error()}
  def blake3_hex(data, server \\ __MODULE__, timeout \\ @default_timeout) when is_binary(data) do
    with :ok <- ensure_utf8(data),
         {:ok, raw} <- transact(server, "blake3_hex", [data], timeout) do
      as_plain_string(raw)
    end
  end

  @doc """
  Runs the engine's hook evaluation over a base graph and an event graph.

  Returns the decoded JSON verdict map, e.g.
  `%{"status" => "ADMITTED", "verdicts" => [], "receipts" => [], "schedule" => []}`.

  An `"ADMITTED"` status here is the engine's *derivation*, not an
  admission decision and not authority — see the NO AUTHORITY section.
  """
  @spec run_hooks(String.t(), String.t(), GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, error()} | {:error, encoding_error()}
  def run_hooks(base_ttl, event_ttl, server \\ __MODULE__, timeout \\ @default_timeout)
      when is_binary(base_ttl) and is_binary(event_ttl) do
    with :ok <- ensure_utf8(base_ttl),
         :ok <- ensure_utf8(event_ttl),
         {:ok, raw} <- transact(server, "run_hooks", [base_ttl, event_ttl], timeout) do
      as_json_map(raw)
    end
  end

  @doc """
  Full multi-dialect validation pass: OWL RL, Datalog, SHACL, ShEx and N3
  denial, plus the engine's own graph hash and a self-replay check.

  All five string arguments are required positionally; pass `""` for any
  dialect you are not supplying, which the engine reports as
  `"UNSUPPORTED"`/`"PROFILE_NOT_ADMITTED"` rather than failing.

  Per-dialect verdicts are reported *inside* the returned map (a SHACL
  parse failure surfaces as that dialect's `"status" => "REFUSED"` with a
  real parser diagnostic, while the overall call still succeeds) — so a
  `{:ok, map}` here means "the engine ran", never "everything validated".
  Callers must read `map["dialects"]`.
  """
  @spec validate_all(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          GenServer.server(),
          timeout()
        ) :: {:ok, map()} | {:error, error()} | {:error, encoding_error()}
  def validate_all(
        ttl,
        profile_ttl,
        shacl_shapes,
        shex_schema,
        shex_shape_map,
        server \\ __MODULE__,
        timeout \\ @default_timeout
      )
      when is_binary(ttl) and is_binary(profile_ttl) and is_binary(shacl_shapes) and
             is_binary(shex_schema) and is_binary(shex_shape_map) do
    args = [ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map]

    with :ok <- ensure_utf8(ttl),
         :ok <- ensure_utf8(profile_ttl),
         :ok <- ensure_utf8(shacl_shapes),
         :ok <- ensure_utf8(shex_schema),
         :ok <- ensure_utf8(shex_shape_map),
         {:ok, raw} <- transact(server, "validate_all", args, timeout) do
      as_json_map(raw)
    end
  end

  @doc """
  Whether a real, loaded engine instance is available on this node.
  """
  @spec available?(GenServer.server(), timeout()) :: boolean()
  def available?(server \\ __MODULE__, timeout \\ @default_timeout) do
    case GenServer.call(server, :status, timeout) do
      {:ok, :loaded} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc """
  Returns `:ok` when `binary` is valid UTF-8, or
  `{:error, {:invalid_encoding, byte_offset}}` naming the first invalid byte.

  Every public function above that takes a string argument calls this BEFORE
  any wasm transaction -- see the module doc's "Non-UTF-8 input is refused
  BEFORE the engine, not after" section for why a single invalid byte cannot
  be allowed to reach `transact/4`. Public (not private) for the same reason
  `AshA2A.Semantic.CanonicalGraph.ensure_utf8/1` is public: any other Elixir
  caller of a wasm string export should run this first too.

  Delegates to `AshA2A.Semantic.CanonicalGraph.ensure_utf8/1`: one encoding
  guard, one typed contract, one byte-offset scanner in this repository.

      iex> AshA2A.GraphLaw.WasmexHost.ensure_utf8("ok")
      :ok

      iex> AshA2A.GraphLaw.WasmexHost.ensure_utf8(<<"ok", 0xFF>>)
      {:error, {:invalid_encoding, 2}}
  """
  @spec ensure_utf8(binary()) :: :ok | {:error, encoding_error()}
  def ensure_utf8(binary) when is_binary(binary),
    do: AshA2A.Semantic.CanonicalGraph.ensure_utf8(binary)

  @doc """
  Returns the real current size, in bytes, of the engine's linear memory.

  Exposed for verification: the regression test for the non-UTF-8
  memory-bomb defect (see the module doc) reads this before and after a
  rejected call to assert the guard actually stops the commit, not just that
  it returns a typed error. Not needed for production use of this module.
  """
  @spec memory_size(GenServer.server(), timeout()) :: {:ok, non_neg_integer()} | {:error, error()}
  def memory_size(server \\ __MODULE__, timeout \\ @default_timeout) do
    GenServer.call(server, :memory_size, timeout)
  catch
    :exit, {:noproc, _} -> {:error, %{code: :graphlaw_not_started, server: server}}
    :exit, {:timeout, _} -> {:error, %{code: :graphlaw_timeout, function: :memory_size}}
  end

  # ---------------------------------------------------------------------
  # Result shaping
  # ---------------------------------------------------------------------

  # `graph_hash`/`blake3_hex`/`graphlaw_version` return a bare string on
  # success and a JSON `{"error": ...}` object on failure. A bare digest is
  # never valid JSON, so a successful decode into a map carrying "error" is
  # an unambiguous engine error.
  defp as_plain_string(raw) do
    case engine_error(raw) do
      {:error, _} = err -> err
      :none -> {:ok, raw}
    end
  end

  defp as_json_map(raw) do
    case engine_error(raw) do
      {:error, _} = err ->
        err

      :none ->
        case JSON.decode(raw) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, other} ->
            {:error, %{code: :unexpected_engine_output, output: other}}

          {:error, reason} ->
            {:error, %{code: :non_json_output, reason: reason, output: raw}}
        end
    end
  end

  defp engine_error(raw) do
    case JSON.decode(raw) do
      {:ok, %{"error" => detail}} -> {:error, %{code: :graphlaw_error, detail: detail}}
      _ -> :none
    end
  end

  # ---------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------

  @doc """
  Starts the supervised engine instance.

  Options: `:name` (default `#{inspect(__MODULE__)}`; `nil` for an unnamed
  pool member), `:wasm_path`, `:expected_sha256` (`:unpinned` opts out of the
  MANIFEST pin), `:fuel`, `:memory_limit_bytes`, `:recycle_bytes`,
  `:registry` (a duplicate-key `Registry` the host joins under `:members`).
  Never fails to start because of a missing or unloadable artifact — that
  becomes a typed error on every call instead (see the module doc).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, opts} ->
        GenServer.start_link(__MODULE__, opts)

      {name, opts} ->
        GenServer.start_link(__MODULE__, [{:registered_as, name} | opts], name: name)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = wasm_path(opts)

    case Keyword.get(opts, :registry) do
      nil -> :ok
      registry -> {:ok, _} = Registry.register(registry, :members, nil)
    end

    case load(path, opts) do
      {:ok, state} ->
        state = Map.put(state, :default?, Keyword.get(opts, :registered_as) == __MODULE__)
        publish(state)
        {:ok, state}

      {:error, reason} ->
        if Keyword.get(opts, :registered_as) == __MODULE__,
          do: :persistent_term.erase({__MODULE__, :loaded})

        Logger.warning(
          "AshA2A.GraphLaw.WasmexHost: engine unavailable (#{inspect(reason)}). " <>
            "GraphLaw-backed calls will return typed errors; nothing else is affected."
        )

        {:ok, %{status: {:unavailable, reason}}}
    end
  end

  defp load(path, opts) do
    load_opts = [fuel?: true, expected_sha256: EngineLoad.expected_sha256(opts)]

    with true <- File.exists?(path) or {:error, %{code: :graphlaw_wasm_not_vendored, path: path}},
         {:ok, bytes} <- read_wasm(path),
         {:ok, entry} <- EngineLoad.load("BEAM/WasmexHost", bytes, load_opts),
         base = %{
           status: :loaded,
           path: path,
           entry: entry,
           wasm_sha256: entry.wasm_sha256,
           fuel: config(opts, :fuel, :graphlaw_fuel_per_call, @default_fuel),
           memory_limit:
             config(
               opts,
               :memory_limit_bytes,
               :graphlaw_memory_limit_bytes,
               @default_memory_limit
             ),
           recycle_bytes:
             config(opts, :recycle_bytes, :graphlaw_memory_recycle_bytes, @default_recycle_bytes),
           recycles: 0
         },
         {:ok, state} <- instantiate(base) do
      {:ok, state}
    else
      {:error, _} = err -> err
      other -> {:error, %{code: :graphlaw_instantiation_failed, detail: other, path: path}}
    end
  end

  defp config(opts, key, env_key, default),
    do: Keyword.get(opts, key) || Application.get_env(:ash_a2a, env_key, default)

  # One fresh store + instance over the cached compiled module.
  defp instantiate(%{entry: entry} = state) do
    limits = %Wasmex.StoreLimits{memory_size: state.memory_limit}

    # Instantiation runs the module's start function (`__wbindgen_start`),
    # which is metered too; it gets the instantiation budget, and every
    # transaction then resets the store to the per-call budget.
    with {:ok, store} <- Wasmex.Store.new(limits, entry.engine),
         :ok <- Wasmex.StoreOrCaller.set_fuel(store, max(state.fuel, @instantiate_fuel)),
         {:ok, pid} <-
           Wasmex.start_link(%{store: store, module: entry.module, imports: imports()}),
         {:ok, store} <- Wasmex.store(pid),
         {:ok, memory} <- Wasmex.memory(pid) do
      {:ok, Map.merge(state, %{pid: pid, store: store, memory: memory})}
    else
      {:error, _} = err -> err
      other -> {:error, %{code: :graphlaw_instantiation_failed, detail: other}}
    end
  end

  # Replaces the instance in-process (the mailbox survives). The old instance
  # is unlinked and killed first so its exit cannot race the new one.
  defp recycle(%{pid: old} = state, reason) do
    Process.unlink(old)
    Process.exit(old, :kill)

    :telemetry.execute(
      [:ash_a2a, :graphlaw, :host, :recycle],
      %{system_time: System.system_time()},
      %{wasm_sha256: state.wasm_sha256, reason: reason}
    )

    case instantiate(state) do
      {:ok, fresh} ->
        %{fresh | recycles: state.recycles + 1}

      {:error, error} ->
        unavailable = %{
          status: {:unavailable, %{code: :graphlaw_instantiation_failed, detail: error}},
          default?: state.default?
        }

        publish(unavailable)
        unavailable
    end
  end

  defp read_wasm(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, %{code: :graphlaw_wasm_unreadable, path: path, reason: reason}}
    end
  end

  # The artifact imports exactly two host functions.
  defp imports do
    %{
      @import_namespace => %{
        # wasm-bindgen's JS-object table drop. This host hands the engine no
        # JS objects at all, so there is nothing to drop: a real no-op, not
        # a stub standing in for behaviour we declined to implement.
        "__wbindgen_object_drop_ref" => {:fn, [:i32], [], fn _context, _handle -> nil end},
        # Real entropy written into real linear memory. See the module doc:
        # feeding a deterministic stream here would fabricate the very
        # determinism the conformance court has to measure.
        "__wbg_getRandomValues_3f44b700395062e5" =>
          {:fn, [:i32, :i32], [],
           fn %{memory: memory, caller: caller}, ptr, len ->
             :ok =
               Wasmex.Memory.write_binary(
                 caller,
                 memory,
                 ptr,
                 :crypto.strong_rand_bytes(max(len, 0))
               )

             nil
           end}
      }
    }
  end

  defp transact(server, fun, args, timeout) do
    with {:ok, target} <- route(server) do
      GenServer.call(target, {:transact, fun, args, timeout}, call_timeout(timeout, 1, args))
    end
  catch
    :exit, {:noproc, _} ->
      {:error, %{code: :graphlaw_not_started, server: server}}

    :exit, {:timeout, _} ->
      {:error, %{code: :graphlaw_timeout, function: fun, timeout: timeout}}
  end

  @doc """
  Runs several raw engine calls in ONE host transaction sequence (one
  `handle_call/3`, no interleaving), returning the raw result strings in
  order: `[{"graph_hash", [ttl]}, {"graphlaw_version", []}]` ->
  `{:ok, [hash, version]}`. The first failure stops the batch.

  Raw means undecoded: an engine error comes back as its `{"error": ...}`
  JSON string, exactly as the node shims return it, so callers keep one
  decoding path across hosts.
  """
  @spec raw_many([{String.t(), [String.t()]}], GenServer.server(), timeout()) ::
          {:ok, [String.t()]} | {:error, error()} | {:error, encoding_error()}
  def raw_many(calls, server \\ __MODULE__, timeout \\ @default_timeout) when is_list(calls) do
    args = Enum.flat_map(calls, fn {_fun, call_args} -> call_args end)

    with :ok <- Enum.reduce_while(args, :ok, &utf8_step/2),
         {:ok, target} <- route(server) do
      GenServer.call(
        target,
        {:transact_many, calls, timeout},
        call_timeout(timeout, length(calls), args)
      )
    end
  catch
    :exit, {:noproc, _} ->
      {:error, %{code: :graphlaw_not_started, server: server}}

    :exit, {:timeout, _} ->
      {:error, %{code: :graphlaw_timeout, function: :raw_many, timeout: timeout}}
  end

  defp utf8_step(arg, :ok) do
    case ensure_utf8(arg) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc """
  `%{wasm_sha256: digest, path: path, recycles: n}` for a loaded host, or the
  typed unavailability reason.
  """
  @spec info(GenServer.server(), timeout()) :: {:ok, map()} | {:error, error()}
  def info(server \\ __MODULE__, timeout \\ @default_timeout) do
    GenServer.call(server, :info, timeout)
  catch
    :exit, {:noproc, _} -> {:error, %{code: :graphlaw_not_started, server: server}}
    :exit, {:timeout, _} -> {:error, %{code: :graphlaw_timeout, function: :info}}
  end

  # The default name routes to the least-loaded member of a running
  # `AshA2A.GraphLaw.WasmexPool`; any explicit server is used as given. Either
  # way a target whose mailbox is already at the shedding bound is refused.
  defp route(__MODULE__ = server) do
    target = AshA2A.GraphLaw.WasmexPool.pick() || server
    shed(target)
  end

  defp route(server), do: shed(server)

  defp shed(target) do
    max = Application.get_env(:ash_a2a, :graphlaw_max_queue, @default_max_queue)

    case GenServer.whereis(target) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} when len >= max ->
            {:error, %{code: :graphlaw_saturated, queue: len, max_queue: max}}

          _ ->
            {:ok, pid}
        end

      _ ->
        {:ok, target}
    end
  end

  # The caller must outlive every inner step it is waiting on: the real call
  # (`timeout` + 1 s reply margin) plus, per engine call, the ABI helper steps
  # (claim, one malloc per argument, free, release), each bounded by
  # `@abi_timeout` + 1 s. Strictly greater than their sum, so a slow engine
  # call surfaces as the host's typed error, never as a caller timeout while
  # the instance is still mid-transaction.
  defp call_timeout(:infinity, _calls, _args), do: :infinity

  defp call_timeout(timeout, calls, args) when is_integer(timeout) do
    steps = calls * 3 + length(args)
    calls * (timeout + 1_000) + steps * (@abi_timeout + 1_000) + 1_000
  end

  @impl true
  def handle_call(:status, _from, %{status: :loaded} = state) do
    {:reply, {:ok, :loaded}, state}
  end

  def handle_call(:status, _from, %{status: {:unavailable, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(:info, _from, %{status: :loaded} = state) do
    {:reply, {:ok, Map.take(state, [:wasm_sha256, :path, :recycles])}, state}
  end

  def handle_call(:info, _from, %{status: {:unavailable, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:transact, _, _, _}, _from, %{status: {:unavailable, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:transact_many, _, _}, _from, %{status: {:unavailable, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:transact, fun, args, timeout}, _from, %{status: :loaded} = state) do
    {result, state} = run_transaction(state, fun, args, timeout)
    {:reply, result, state}
  end

  def handle_call({:transact_many, calls, timeout}, _from, %{status: :loaded} = state) do
    {results, state} =
      Enum.reduce_while(calls, {[], state}, fn {fun, args}, {acc, st} ->
        case run_transaction(st, fun, args, timeout) do
          {{:ok, raw}, st} when st.status == :loaded -> {:cont, {[raw | acc], st}}
          {{:ok, _raw}, st} -> {:halt, {{:error, st.status}, st}}
          {{:error, _} = err, st} -> {:halt, {err, st}}
        end
      end)

    reply =
      case results do
        list when is_list(list) -> {:ok, Enum.reverse(list)}
        {:error, _} = err -> err
      end

    {:reply, reply, state}
  end

  def handle_call(
        :memory_size,
        _from,
        %{status: :loaded, store: store, memory: memory} = state
      ) do
    {:reply, {:ok, Wasmex.Memory.size(store, memory)}, state}
  end

  def handle_call(:memory_size, _from, %{status: {:unavailable, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :default?), do: :persistent_term.erase({__MODULE__, :loaded})
    :ok
  end

  # The default-named host publishes its loaded digest so routing
  # (`loaded_sha256/0`) never has to queue a `:status` call behind a running
  # transaction. Only written on a load/unload edge, never per call.
  defp publish(%{default?: true, status: :loaded, wasm_sha256: sha, path: path}),
    do: :persistent_term.put({__MODULE__, :loaded}, {sha, Path.expand(path)})

  defp publish(%{default?: true}), do: :persistent_term.erase({__MODULE__, :loaded})
  defp publish(_state), do: :ok

  @doc """
  The pinned SHA-256 the default-named host has loaded, or `nil` when it is
  not running or not loaded. Lock-free: no call to the host.
  """
  @spec loaded_sha256() :: String.t() | nil
  def loaded_sha256 do
    case loaded() do
      {sha, _path} -> sha
      nil -> nil
    end
  end

  @doc """
  `{sha256, expanded_wasm_path}` of the default-named host's loaded engine,
  or `nil`. Transports use the path to decide whether the warm host is a
  truthful answer: only when THEIR resolved wasm path is the one it loaded.
  """
  @spec loaded() :: {String.t(), String.t()} | nil
  def loaded do
    with {sha, path} <- :persistent_term.get({__MODULE__, :loaded}, nil),
         pid when is_pid(pid) <- Process.whereis(__MODULE__) do
      {sha, path}
    else
      _ -> nil
    end
  end

  @doc "Whether the default host has loaded exactly the wasm at `path`."
  @spec serves?(String.t()) :: boolean()
  def serves?(path) when is_binary(path) do
    case loaded() do
      {_sha, loaded_path} -> loaded_path == Path.expand(path)
      nil -> false
    end
  end

  # The instance died outside a call (it is linked and this host traps exits):
  # replace it rather than dying with it.
  @impl true
  def handle_info({:EXIT, pid, reason}, %{status: :loaded, pid: pid} = state) do
    {:noreply, recycle(state, {:instance_exit, inspect(reason, limit: 5)})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @recycle_codes [:graphlaw_call_failed, :graphlaw_call_exited, :graphlaw_abi_failure]

  defp run_transaction(state, fun, args, timeout) do
    :ok = Wasmex.StoreOrCaller.set_fuel(state.store, state.fuel)
    result = do_transact(state, fun, args, timeout)
    AshA2A.GraphLaw.EngineTelemetry.emit("BEAM/WasmexHost", state.wasm_sha256, fun, result)
    {result, maybe_recycle(state, result)}
  end

  defp maybe_recycle(state, {:error, %{code: code}}) when code in @recycle_codes,
    do: recycle(state, code)

  defp maybe_recycle(%{store: store, memory: memory} = state, _result) do
    if Wasmex.Memory.size(store, memory) > state.recycle_bytes,
      do: recycle(state, :memory_high_water),
      else: state
  end

  # ---------------------------------------------------------------------
  # wasm-bindgen ABI marshaling (ported from a shim proven against this
  # exact artifact under a second, independent host runtime)
  # ---------------------------------------------------------------------

  defp do_transact(state, fun, args, timeout) do
    case claim_return_slot(state) do
      {:ok, retptr} ->
        try do
          with {:ok, arg_words} <- write_args(state, args) do
            invoke(state, fun, [retptr | arg_words], retptr, timeout)
          end
        after
          release_return_slot(state)
        end

      {:error, _} = err ->
        err
    end
  end

  defp claim_return_slot(state) do
    case call_raw(state, "__wbindgen_add_to_stack_pointer", [-@ret_slot], @abi_timeout) do
      {:ok, [retptr]} -> {:ok, retptr}
      other -> {:error, %{code: :graphlaw_abi_failure, step: :claim_return_slot, detail: other}}
    end
  end

  defp release_return_slot(state) do
    _ = call_raw(state, "__wbindgen_add_to_stack_pointer", [@ret_slot], @abi_timeout)
    :ok
  end

  # Each string argument becomes a (ptr, len) pair in the flattened arg list.
  defp write_args(state, args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case write_string(state, arg) do
        {:ok, ptr} -> {:cont, {:ok, acc ++ [ptr, byte_size(arg)]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp write_string(%{store: store, memory: memory} = state, binary) do
    size = byte_size(binary)

    case call_raw(state, "__wbindgen_export2", [size, 1], @abi_timeout) do
      {:ok, [ptr]} ->
        case Wasmex.Memory.write_binary(store, memory, ptr, binary) do
          :ok -> {:ok, ptr}
          other -> {:error, %{code: :graphlaw_abi_failure, step: :write_binary, detail: other}}
        end

      other ->
        {:error, %{code: :graphlaw_abi_failure, step: :malloc, detail: other}}
    end
  end

  defp invoke(%{store: store, memory: memory} = state, fun, params, retptr, timeout) do
    case call_raw(state, fun, params, timeout) do
      {:ok, _} ->
        header = Wasmex.Memory.read_binary(store, memory, retptr, @ret_header)
        read_result(state, header)

      {:error, %{code: :graphlaw_call_exited}} = exited ->
        exited

      {:error, reason} ->
        {:error, %{code: :graphlaw_call_failed, function: fun, reason: reason}}

      other ->
        {:error, %{code: :graphlaw_call_failed, function: fun, reason: other}}
    end
  end

  defp read_result(state, <<ptr::little-signed-32, len::little-signed-32>>)
       when ptr >= 0 and len >= 0 do
    %{store: store, memory: memory} = state

    try do
      {:ok, Wasmex.Memory.read_binary(store, memory, ptr, len)}
    after
      # Free the engine-allocated result string. Guaranteed to run even if
      # reading it raises, so a failed read cannot leak linear memory.
      _ = call_raw(state, "__wbindgen_export4", [ptr, len, 1], @abi_timeout)
    end
  end

  defp read_result(_state, header) do
    {:error, %{code: :graphlaw_abi_failure, step: :read_result, header: header}}
  end

  # A direct call into the Wasmex GenServer so the native interrupt deadline
  # and the caller deadline differ: the native epoch interrupt fires first and
  # comes back as `{:error, _}`, and the caller waits 1 s longer. Any exit
  # (the instance crashed, or the reply still lost the race) is caught and
  # typed here -- it must never propagate into this host's `handle_call/3`.
  defp call_raw(%{pid: pid}, fun, params, timeout) do
    {native, caller} =
      case timeout do
        :infinity -> {nil, :infinity}
        ms when is_integer(ms) -> {ms, ms + 1_000}
      end

    GenServer.call(pid, {:call_function, fun, params, native}, caller)
  catch
    :exit, reason ->
      {:error, %{code: :graphlaw_call_exited, function: fun, reason: inspect(reason, limit: 5)}}
  end
end
