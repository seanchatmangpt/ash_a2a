defmodule AshA2A.GraphLaw.Wasm do
  @moduledoc """
  Real invocation of the prebuilt `praxis-graphlaw` WebAssembly module.

  This module writes no validation logic. It is a transport: it hands Turtle
  text to the real GraphLaw wasm (native N3, Datalog, SPARQL 1.1, SHACL, ShEx,
  graph digesting) and returns what that engine actually said. Every
  SHACL/ShEx/Datalog/N3 decision in `AshA2A` comes from this engine -- there is
  deliberately no Elixir reimplementation of any of it.

  Canonical *identity* is the one exception, and deliberately so: the engine's
  `graph_hash/2` export is prefix- and order-invariant but **not**
  blank-node-relabel invariant, so it is not RDFC-1.0 (see that function's
  docs for the measured digests). RFC S12 canonical graph identity is
  RDF.ex's in-BEAM `RDF.Graph.canonical_hash/1` instead.

  ## Why a subprocess host

  The prebuilt artifact in `praxis-graphlaw-wasm/pkg` is a wasm-pack **bundler**
  target: its sibling `praxis_graphlaw_wasm.js` glue does not load under plain
  Node ESM, and the module is not a WASI command, so `wasmtime` cannot run it
  from the CLI either. `priv/graphlaw/graphlaw_host.mjs` instantiates the
  `_bg.wasm` directly, supplies the two host imports it really declares
  (`__wbindgen_object_drop_ref`, `__wbg_getRandomValues_3f44b700395062e5`), and
  implements the wasm-bindgen string ABI against real linear memory.

  This mirrors the real-subprocess pattern `AshA2A.Planning.HddlSolver` already
  established for the native `hddl_cli` binary: a real OS process running a real
  engine over real files, decoded with the built-in `JSON` module.

  ## Batching

  Instantiating a 3.2 MB wasm module costs real time, so `batch/2` runs a whole
  list of calls inside one process and one instantiation. `AshA2A.Semantic.AdmissionPipeline`
  issues exactly one `batch/2` per admission attempt.

  ## Measured engine behaviour this module does not paper over

  `graph_hash/2` returns a hash for input that is not valid Turtle at all --
  malformed input does not raise and does not return an `"error"` key. Callers
  must therefore never read "a hash came back" as "the document parsed". The
  real, engine-native parse witness is a universal denial rule
  (`{ ?s ?p ?o } => false .`): `N3_DENIAL` reports `REFUSED` iff the parsed
  graph contains at least one triple. `AshA2A.Semantic.AdmissionPipeline`'s
  Parse stage uses exactly that witness.

  All exported functions return `{"error": "..."}` JSON rather than raising on
  bad input, so `decode_json/1` surfaces that as `{:error, ...}` for callers.
  """

  @default_wasm_path "/Users/sac/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm"

  @host_script Path.expand("../../../priv/graphlaw/graphlaw_host.mjs", __DIR__)

  @typedoc "One real call into the wasm: an exported function name and its string arguments."
  @type call :: {atom() | String.t(), [String.t()]}

  @doc """
  Resolves the real path of the GraphLaw wasm artifact.

  Order: `opts[:wasm_path]`, then `Application.get_env(:ash_a2a, :graphlaw_wasm_path)`,
  then a build-machine default. Configurable rather than hardcoded for the same
  reason `AshA2A.Planning.HddlSolver.cli_path/1` is: the artifact lives outside
  this repo and outside the published hex package.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path, @default_wasm_path)
  end

  @doc """
  Resolves the real Node host script path (`opts[:host_script]` overrides).
  """
  @spec host_script(keyword()) :: String.t()
  def host_script(opts \\ []), do: Keyword.get(opts, :host_script, @host_script)

  @doc """
  True iff the real wasm artifact, the real host script, and a real `node`
  executable are all present. Tests use this for a **named, visible skip** --
  never for a silent substitution of a fake engine.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    File.exists?(wasm_path(opts)) and File.exists?(host_script(opts)) and
      node_executable(opts) != nil
  end

  @doc """
  Explains, in real measured terms, why `available?/1` is false. Returns `:ok`
  when the engine is actually runnable.
  """
  @spec availability(keyword()) :: :ok | {:error, map()}
  def availability(opts \\ []) do
    cond do
      (path = wasm_path(opts)) && not File.exists?(path) ->
        {:error, %{code: :graphlaw_wasm_not_found, path: path}}

      (script = host_script(opts)) && not File.exists?(script) ->
        {:error, %{code: :graphlaw_host_script_not_found, path: script}}

      node_executable(opts) == nil ->
        {:error, %{code: :node_executable_not_found}}

      true ->
        :ok
    end
  end

  @doc """
  Runs a list of real wasm calls inside one real host process and one real wasm
  instantiation.

  Returns `{:ok, [String.t()]}` with one raw result string per call, in order,
  or `{:error, map()}` carrying a `:code` key. Never raises for an engine-level
  problem: a missing artifact, a non-zero host exit, non-JSON host output, and a
  host-reported failure are all typed errors.
  """
  @spec batch([call()], keyword()) :: {:ok, [String.t()]} | {:error, map()}
  def batch(calls, opts \\ []) when is_list(calls) do
    result =
      with :ok <- availability(opts),
           {:ok, request} <- encode_request(calls, opts) do
        run_host(request, opts)
      end

    # Boundary telemetry (RFC-SA2A-002 §12/§18): which wasm path the real host
    # was handed and whether it answered. Observational only.
    :telemetry.execute(
      [:ash_a2a, :graph_law, :wasm, :batch],
      %{calls: length(calls)},
      %{wasm_path: wasm_path(opts), outcome: elem(result, 0), code: error_code(result)}
    )

    result
  end

  defp error_code({:error, %{code: code}}), do: code
  defp error_code(_result), do: nil

  @doc "Real `graphlaw_version()` from the wasm (e.g. `\"praxis-graphlaw v26.7.5\"`)."
  @spec version(keyword()) :: {:ok, String.t()} | {:error, map()}
  def version(opts \\ []), do: single({:graphlaw_version, []}, opts)

  @doc """
  Real `graph_hash(ttl)` from the engine: a BLAKE3 digest over the engine's own
  normalized reading of `ttl`.

  **This is not full RDFC-1.0 and must not be described as such.** Measured
  behaviour of this export:

    * Invariant under prefix relabeling and under triple reordering -- a graph
      rewritten with different prefixes and a shuffled statement order hashes
      identically.
    * **Not** invariant under blank-node relabeling. The same graph written
      with `_:b1` and with `_:zzz9` produces two different digests
      (`0b779749...` and `402f61fc...`), where a real RDFC-1.0 canonicalization
      produces one (`7a72254e...`, measured via `RDF.Graph.canonical_hash/1`).
    * Unparseable input does not error: `graph_hash("@@@ not turtle")` equals
      `graph_hash("")` equals `blake3("")` equals
      `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`.

  So a caller must never read "a hash came back" as "the document parsed", and
  must never read "the hashes match" as "these are the same RDF graph under
  RDFC-1.0". RFC S12 canonical graph identity in this codebase is RDF.ex's
  in-BEAM `RDF.Graph.canonical_hash/1` (see
  `AshA2A.Semantic.AdmissionPipeline`'s Identity stage), which is
  blank-node-relabel invariant and whose Turtle reader fails closed. This
  export is retained as the engine's own digest of what the engine judged --
  which is exactly what the admission receipt needs to record.
  """
  @spec graph_hash(String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def graph_hash(ttl, opts \\ []) when is_binary(ttl),
    do: single({:graph_hash, [ttl]}, opts)

  @doc "Real BLAKE3 hex digest of `input` computed inside the wasm."
  @spec blake3_hex(String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def blake3_hex(input, opts \\ []) when is_binary(input),
    do: single({:blake3_hex, [input]}, opts)

  @doc """
  Real `validate_all/5`: runs the OWL_RL, DATALOG, SHACL, SHEX and N3_DENIAL
  dialects over `ttl` and returns the decoded report map.

  Each entry of the report's `"dialects"` list carries `"dialect"`, `"status"`
  (`"ADMITTED"` | `"REFUSED"` | `"UNSUPPORTED"` | `"PROFILE_NOT_ADMITTED"`),
  `"detail"` and `"triples_out"`. Pass `""` for any of `profile_ttl`,
  `shacl_shapes`, `shex_schema`, `shex_shape_map` that is not supplied -- the
  engine then reports that dialect as `UNSUPPORTED`/`PROFILE_NOT_ADMITTED`,
  which `AshA2A.Semantic.AdmissionPipeline` treats as *undetermined*, and
  therefore as a refusal, never as a pass.
  """
  @spec validate_all(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map, opts \\ [])
      when is_binary(ttl) and is_binary(profile_ttl) and is_binary(shacl_shapes) and
             is_binary(shex_schema) and is_binary(shex_shape_map) do
    with {:ok, raw} <-
           single(
             {:validate_all, [ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map]},
             opts
           ) do
      decode_json(raw)
    end
  end

  @doc """
  Real `run_hooks/2` over a base graph and an event graph. Returns the decoded
  map, whose `"status"` is the engine's own admission verdict for the hook set.
  """
  @spec run_hooks(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run_hooks(base_ttl, event_ttl, opts \\ [])
      when is_binary(base_ttl) and is_binary(event_ttl) do
    with {:ok, raw} <- single({:run_hooks, [base_ttl, event_ttl]}, opts), do: decode_json(raw)
  end

  @doc """
  Decodes one raw engine result as JSON, mapping the engine's own
  `{"error": "..."}` convention onto `{:error, %{code: :graphlaw_engine_error}}`.
  """
  @spec decode_json(String.t()) :: {:ok, map()} | {:error, map()}
  def decode_json(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{"error" => message}} ->
        {:error, %{code: :graphlaw_engine_error, message: message}}

      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, %{code: :graphlaw_unexpected_result, result: other}}

      {:error, reason} ->
        {:error, %{code: :graphlaw_non_json_result, reason: reason, raw: raw}}
    end
  end

  @doc """
  Looks up a dialect entry by name in a decoded `validate_all/6` report.

  Returns `{:ok, entry}` or `{:error, %{code: :graphlaw_dialect_missing}}` --
  an absent dialect is an *undetermined* predicate, never a passing one.
  """
  @spec dialect(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def dialect(%{"dialects" => dialects}, name) when is_list(dialects) and is_binary(name) do
    case Enum.find(dialects, &(is_map(&1) and Map.get(&1, "dialect") == name)) do
      nil -> {:error, %{code: :graphlaw_dialect_missing, dialect: name}}
      entry -> {:ok, entry}
    end
  end

  def dialect(report, name),
    do: {:error, %{code: :graphlaw_report_malformed, dialect: name, report: report}}

  defp single(call, opts) do
    case batch([call], opts) do
      {:ok, [result]} -> {:ok, result}
      {:ok, other} -> {:error, %{code: :graphlaw_result_arity, results: other}}
      {:error, _} = error -> error
    end
  end

  defp encode_request(calls, opts) do
    encoded =
      Enum.map(calls, fn {fn_name, args} ->
        %{"fn" => to_string(fn_name), "args" => args}
      end)

    {:ok, JSON.encode!(%{"wasm_path" => wasm_path(opts), "calls" => encoded})}
  rescue
    error -> {:error, %{code: :graphlaw_request_not_encodable, reason: Exception.message(error)}}
  end

  defp run_host(request, opts) do
    node = node_executable(opts)
    script = host_script(opts)
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = System.unique_integer([:positive, :monotonic])
    request_path = Path.join(tmp_dir, "ash_a2a_graphlaw_request_#{unique}.json")

    File.write!(request_path, request)

    try do
      case System.cmd(node, [script, request_path], stderr_to_stdout: false) do
        {stdout, 0} -> decode_host_output(stdout)
        {stdout, code} -> {:error, %{code: :graphlaw_host_exit, exit: code, stdout: stdout}}
      end
    after
      File.rm(request_path)
    end
  end

  defp decode_host_output(stdout) do
    case JSON.decode(stdout) do
      {:ok, %{"ok" => true, "results" => results}} when is_list(results) ->
        {:ok, results}

      {:ok, %{"ok" => false, "error" => message}} ->
        {:error, %{code: :graphlaw_host_error, message: message}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_host_unexpected, output: other}}

      {:error, reason} ->
        {:error, %{code: :graphlaw_host_non_json, reason: reason, stdout: stdout}}
    end
  end

  defp node_executable(opts) do
    Keyword.get(opts, :node) || Application.get_env(:ash_a2a, :node_executable) ||
      System.find_executable("node")
  end
end
