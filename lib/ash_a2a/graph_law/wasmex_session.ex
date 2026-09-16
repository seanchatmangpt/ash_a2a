defmodule AshA2A.GraphLaw.WasmexSession do
  @moduledoc """
  Runtime A of the SA2A conformance court: the **in-BEAM** WebAssembly host.

  Loads the real prebuilt `praxis_graphlaw_wasm_bg.wasm` into a real
  `:wasmex` instance (Wasmtime engine, reached through a Rustler NIF) running
  inside this BEAM node, and calls the real exported GraphLaw functions over
  it. Nothing here evaluates SHACL, ShEx, Datalog, N3 or SPARQL, and nothing
  here canonicalizes RDF -- every value this module returns is the verbatim
  string the WASM module produced.

  ## Why the raw `wasm-bindgen` ABI is re-implemented here

  The module in `praxis-graphlaw-wasm/pkg/` is built for the wasm-bindgen
  **bundler** target. Its generated `praxis_graphlaw_wasm.js` glue is an ES
  module full of bundler-only imports and is unusable from the BEAM, so this
  module speaks the underlying ABI directly. That ABI, confirmed against the
  real module:

      __wbindgen_export2(len, align)                  -> ptr     (malloc)
      __wbindgen_export3(ptr, old_len, new_len, align) -> ptr     (realloc)
      __wbindgen_export4(ptr, len, align)              -> ()      (free)
      __wbindgen_add_to_stack_pointer(-16)             -> retptr

  A `String`-returning function with N string parameters is invoked as
  `f(retptr, ptr0, len0, ..., ptrN, lenN)`; the result is then two
  little-endian `i32` at `retptr` and `retptr + 4`, giving `(ptr, len)` of a
  UTF-8 string in linear memory, which the caller decodes and frees.

  ## Error discipline

  Every GraphLaw entry point returns `{"error": "..."}` JSON *instead of*
  raising, so `{:ok, string}` from `call/3` means "the WASM call completed",
  not "the WASM call succeeded". Callers -- `AshA2A.SA2A.Conformance` in
  particular -- must inspect the payload for an `"error"` key.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.{EngineLoad, EngineTelemetry, Runtime}

  @import_module "./praxis_graphlaw_wasm_bg.js"
  @random_import "__wbg_getRandomValues_3f44b700395062e5"
  @drop_import "__wbindgen_object_drop_ref"

  @arity %{
    graphlaw_version: 0,
    validate_all: 5,
    graph_hash: 1,
    run_hooks: 2,
    blake3_hex: 1
  }

  @doc false
  # RFC-SA2A-001 S42 classes for the transport codes a bounded call can return.
  def __sa2a_refusal_codes__,
    do: %{graphlaw_call_trapped: :blocked_resource, graphlaw_call_exited: :blocked_resource}

  @impl true
  def host_id, do: "BEAM/Wasmex"

  @impl true
  def engine_id, do: "wasmtime"

  @impl true
  def available?(opts \\ []) do
    path = Runtime.wasm_path(opts)

    cond do
      not Code.ensure_loaded?(Wasmex) ->
        {:error,
         %{
           code: :wasmex_unavailable,
           message: "the :wasmex dependency is not loaded in this runtime"
         }}

      not File.exists?(path) ->
        {:error,
         %{
           code: :graphlaw_wasm_not_found,
           path: path,
           message:
             "GraphLaw wasm not found at #{path}. Build it in the praxis checkout " <>
               "(crates/praxis-graphlaw-wasm) or set :graphlaw_wasm_path / PRAXIS_GRAPHLAW_WASM."
         }}

      true ->
        :ok
    end
  end

  @impl true
  def open(opts \\ []) do
    with :ok <- available?(opts) do
      path = Runtime.wasm_path(opts)
      bytes = File.read!(path)
      digest = Runtime.bytes_digest(bytes)

      case start_instance(bytes, opts) do
        {:ok, pid, import_names} ->
          {:ok, store} = Wasmex.store(pid)
          {:ok, memory} = Wasmex.memory(pid)

          {:ok,
           %{
             session: %{
               pid: pid,
               store: store,
               memory: memory,
               wasm_path: path,
               bounded?: bounded?(opts),
               call_timeout_ms: Keyword.get(opts, :call_timeout_ms, 5_000),
               module_imports: import_names,
               wasm_sha256: digest
             },
             wasm_digest: digest
           }}

        {:error, %{code: code} = refused}
        when code in [:graphlaw_import_surface_mismatch, :graphlaw_wasm_invalid] ->
          {:error, Map.put(refused, :path, path)}

        {:error, reason} ->
          {:error, %{code: :wasmex_instantiate_failed, reason: inspect(reason), path: path}}
      end
    end
  end

  # Bounded sessions (RFC-SA2A-002 §47 finite termination): `:fuel` meters
  # every executed wasm instruction deterministically (a trap when it runs
  # out), `:memory_limit_bytes` caps linear-memory growth, and
  # `:call_timeout_ms` bounds wall time via Wasmex's native interrupt. Without
  # any of them the session is built exactly as before.
  defp bounded?(opts),
    do: Enum.any?([:fuel, :memory_limit_bytes], &Keyword.has_key?(opts, &1))

  defp start_instance(bytes, opts) do
    if bounded?(opts) do
      config = Wasmex.EngineConfig.consume_fuel(%Wasmex.EngineConfig{}, true)
      limits = %Wasmex.StoreLimits{memory_size: Keyword.get(opts, :memory_limit_bytes)}

      with {:ok, engine} <- Wasmex.Engine.new(config),
           {:ok, store} <- Wasmex.Store.new(limits, engine),
           :ok <- Wasmex.StoreOrCaller.set_fuel(store, Keyword.get(opts, :fuel, 0)),
           {:ok, module} <- EngineLoad.admit(host_id(), bytes, store),
           {:ok, pid} <- Wasmex.start_link(%{store: store, module: module, imports: imports()}) do
        {:ok, pid, module |> Wasmex.Module.imports() |> EngineLoad.import_names()}
      end
    else
      # The surface is admitted before `Wasmex.start_link/1`: a foreign import
      # surface otherwise crashes the linked caller from Wasmex's `init/1`.
      with {:ok, store} <- Wasmex.Store.new(),
           {:ok, module} <- EngineLoad.admit(host_id(), bytes, store),
           {:ok, pid} <- Wasmex.start_link(%{store: store, module: module, imports: imports()}),
           do: {:ok, pid, nil}
    end
  end

  @doc """
  The two host imports every session supplies, as `"module::name"`. A module
  whose import surface is anything else can reach the host some other way.
  """
  @spec pinned_imports() :: [String.t()]
  def pinned_imports,
    do: Enum.sort(["#{@import_module}::#{@drop_import}", "#{@import_module}::#{@random_import}"])

  @doc "Fuel left in a bounded session's store (`nil` for an unbounded one)."
  @spec fuel_remaining(map()) :: non_neg_integer() | nil
  def fuel_remaining(%{bounded?: true, store: store}) do
    case Wasmex.StoreOrCaller.get_fuel(store) do
      {:ok, fuel} -> fuel
      _ -> nil
    end
  end

  def fuel_remaining(_session), do: nil

  @doc "Current (= peak: wasm linear memory never shrinks) linear-memory size in bytes."
  @spec memory_bytes(map()) :: non_neg_integer() | nil
  def memory_bytes(%{store: store, memory: memory}), do: Wasmex.Memory.size(store, memory)

  @impl true
  def call(session, fun, args) when is_atom(fun) and is_list(args) do
    expected = Map.fetch!(@arity, fun)

    if length(args) != expected do
      {:error,
       %{code: :graphlaw_arity_mismatch, function: fun, expected: expected, got: length(args)}}
    else
      name = Atom.to_string(fun)
      result = do_call(session, name, args)
      EngineTelemetry.emit(host_id(), Map.get(session, :wasm_sha256), name, result)
      result
    end
  end

  @impl true
  def close(%{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # -- real wasm-bindgen ABI ------------------------------------------------

  defp do_call(%{pid: pid, store: store, memory: memory} = session, fun, args) do
    timeout = Map.get(session, :call_timeout_ms, 5_000)

    {:ok, [retptr]} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [-16])

    ptr_lens =
      Enum.flat_map(args, fn arg ->
        len = byte_size(arg)
        {:ok, [ptr]} = Wasmex.call_function(pid, "__wbindgen_export2", [max(len, 1), 1])
        :ok = Wasmex.Memory.write_binary(store, memory, ptr, arg)
        [ptr, len]
      end)

    case Wasmex.call_function(pid, fun, [retptr | ptr_lens], timeout) do
      {:ok, []} -> read_result(pid, store, memory, retptr)
      {:error, reason} -> {:error, %{code: :graphlaw_call_trapped, function: fun, reason: reason}}
    end
  rescue
    error ->
      {:error, %{code: :graphlaw_call_raised, function: fun, error: Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, %{code: :graphlaw_call_exited, function: fun, reason: inspect(reason)}}
  end

  defp read_result(pid, store, memory, retptr) do
    <<result_ptr::little-signed-32, result_len::little-signed-32>> =
      Wasmex.Memory.read_binary(store, memory, retptr, 8)

    out = Wasmex.Memory.read_binary(store, memory, result_ptr, result_len)

    {:ok, _} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [16])
    {:ok, []} = Wasmex.call_function(pid, "__wbindgen_export4", [result_ptr, result_len, 1])

    {:ok, out}
  end

  defp imports do
    %{
      @import_module => %{
        @drop_import => {:fn, [:i32], [], fn _context, _handle -> nil end},
        @random_import =>
          {:fn, [:i32, :i32], [],
           fn context, ptr, len ->
             bytes = Runtime.deterministic_random_bytes(len)
             Wasmex.Memory.write_binary(context.caller, context.memory, ptr, bytes)
             nil
           end}
      }
    }
  end
end
