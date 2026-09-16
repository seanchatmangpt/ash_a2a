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

  alias AshA2A.GraphLaw.Runtime

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

      case Wasmex.start_link(%{bytes: bytes, imports: imports()}) do
        {:ok, pid} ->
          {:ok, store} = Wasmex.store(pid)
          {:ok, memory} = Wasmex.memory(pid)

          {:ok,
           %{
             session: %{pid: pid, store: store, memory: memory, wasm_path: path},
             wasm_digest: Runtime.bytes_digest(bytes)
           }}

        {:error, reason} ->
          {:error, %{code: :wasmex_instantiate_failed, reason: inspect(reason), path: path}}
      end
    end
  end

  @impl true
  def call(session, fun, args) when is_atom(fun) and is_list(args) do
    expected = Map.fetch!(@arity, fun)

    if length(args) != expected do
      {:error,
       %{code: :graphlaw_arity_mismatch, function: fun, expected: expected, got: length(args)}}
    else
      do_call(session, Atom.to_string(fun), args)
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

  defp do_call(%{pid: pid, store: store, memory: memory}, fun, args) do
    {:ok, [retptr]} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [-16])

    ptr_lens =
      Enum.flat_map(args, fn arg ->
        len = byte_size(arg)
        {:ok, [ptr]} = Wasmex.call_function(pid, "__wbindgen_export2", [max(len, 1), 1])
        :ok = Wasmex.Memory.write_binary(store, memory, ptr, arg)
        [ptr, len]
      end)

    {:ok, []} = Wasmex.call_function(pid, fun, [retptr | ptr_lens])

    <<result_ptr::little-signed-32, result_len::little-signed-32>> =
      Wasmex.Memory.read_binary(store, memory, retptr, 8)

    out = Wasmex.Memory.read_binary(store, memory, result_ptr, result_len)

    {:ok, _} = Wasmex.call_function(pid, "__wbindgen_add_to_stack_pointer", [16])
    {:ok, []} = Wasmex.call_function(pid, "__wbindgen_export4", [result_ptr, result_len, 1])

    {:ok, out}
  rescue
    error ->
      {:error, %{code: :graphlaw_call_raised, function: fun, error: Exception.message(error)}}
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
