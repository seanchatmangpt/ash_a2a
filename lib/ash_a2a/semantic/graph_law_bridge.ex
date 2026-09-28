defmodule AshA2A.Semantic.GraphLawBridge do
  @moduledoc """
  Real invocation of the real praxis-graphlaw WebAssembly engine from Elixir.

  This module is a **transport**, not an engine. It owns zero RDF logic: every
  parse, hash, validation and entailment happens inside the real
  `praxis_graphlaw_wasm_bg.wasm` build of the Rust `praxis-graphlaw` crate
  (native N3, Datalog, SPARQL 1.1, SHACL, ShEx). Elixir's job at this boundary
  is bytes in, bytes out -- per RFC-SA2A-001's separation of the A2A/standing
  layer from the semantic engine.

  ## Host resolution order

    1. `AshA2A.GraphLaw.WasmexHost` -- the application-supervised, warm,
       in-BEAM Wasmtime instance (or the least-loaded member of an
       `AshA2A.GraphLaw.WasmexPool`), used whenever it has loaded the pinned
       engine and the caller did not name an explicit `:wasm_path`. A call
       costs ~0.5 ms instead of the ~100 ms of a `node` spawn plus a fresh
       3.2 MB instantiation (PERF-01, measured), and `call_many/2` runs a whole
       batch inside one host transaction sequence (PERF-08).
    2. A real `node` subprocess over `priv/graphlaw/graphlaw_invoke.mjs`,
       following the real-subprocess pattern of `AshA2A.Planning.HddlSolver`,
       bounded by `AshA2A.GraphLaw.Subprocess` (deadline + concurrency cap).
       This stays the second runtime of the cross-runtime court and the only
       host that honours a per-call `:wasm_path`.

  The engine version is memoized per wasm identity (the in-BEAM host's pinned
  SHA-256, or the node shim's `{path, size, mtime}`), since it cannot change
  for a fixed artifact.

  Nothing here simulates a result. Every `{:ok, _}` this module returns came
  out of the real wasm module's linear memory.

  ## Configuration

      config :ash_a2a,
        graphlaw_wasm_path: "/abs/path/praxis_graphlaw_wasm_bg.wasm",
        graphlaw_node_path: "node"

  `graphlaw_wasm_path` also honours the `ASH_A2A_GRAPHLAW_WASM` environment
  variable, falling back to the vendored, git-tracked, MANIFEST-pinned artifact
  `AshA2A.GraphLaw.wasm_path/0` (`priv/graphlaw/praxis_graphlaw.wasm`), which is
  present in every checkout -- `available?/0` still reports an unresolvable
  explicit path honestly instead of raising.
  """

  alias AshA2A.Semantic.Serialize

  @doc "Absolute path of the real praxis-graphlaw wasm module."
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      System.get_env("ASH_A2A_GRAPHLAW_WASM") ||
      AshA2A.GraphLaw.wasm_path()
  end

  @doc "Absolute path of the real Node host shim shipped in `priv/`."
  @spec shim_path() :: String.t()
  def shim_path do
    case :code.priv_dir(:ash_a2a) do
      {:error, _} -> Path.expand("../../../priv/graphlaw/graphlaw_invoke.mjs", __DIR__)
      dir -> Path.join([to_string(dir), "graphlaw", "graphlaw_invoke.mjs"])
    end
  end

  @doc "Executable used to run the host shim."
  @spec node_path(keyword()) :: String.t()
  def node_path(opts \\ []) do
    Keyword.get(opts, :node_path) || Application.get_env(:ash_a2a, :graphlaw_node_path) || "node"
  end

  @doc """
  True iff a real GraphLaw host is actually reachable on this machine: either
  an in-BEAM `AshA2A.GraphLaw.Wasm`, or a real `node` executable plus a real
  wasm file plus the shipped shim.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    in_beam_host?(opts) or
      (find_node(opts) != nil and File.exists?(wasm_path(opts)) and
         File.exists?(shim_path()))
  end

  @doc """
  Reports which host would actually serve a call -- `:in_beam`, `:node_shim`,
  or `{:unavailable, reason_map}`. Useful in receipts: the host identity is
  part of the SA2A conformance subject.
  """
  @spec host(keyword()) :: :in_beam | :node_shim | {:unavailable, map()}
  def host(opts \\ []) do
    cond do
      in_beam_host?(opts) ->
        :in_beam

      find_node(opts) == nil ->
        {:unavailable, %{code: :graphlaw_node_not_found, node_path: node_path(opts)}}

      not File.exists?(wasm_path(opts)) ->
        {:unavailable, %{code: :graphlaw_wasm_not_found, wasm_path: wasm_path(opts)}}

      not File.exists?(shim_path()) ->
        {:unavailable, %{code: :graphlaw_shim_not_found, shim_path: shim_path()}}

      true ->
        :node_shim
    end
  end

  @doc "Real `graphlaw_version()` string from the engine."
  @spec version(keyword()) :: {:ok, String.t()} | {:error, map()}
  def version(opts \\ []) do
    key = {__MODULE__, :version, version_identity(opts)}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, version} <- call_one("graphlaw_version", [], opts) do
          :persistent_term.put(key, version)
          {:ok, version}
        end

      version ->
        {:ok, version}
    end
  end

  # What pins the version: the in-BEAM host's loaded SHA-256, or the node
  # shim's artifact file identity (a re-vendored file changes size or mtime).
  defp version_identity(opts) do
    case in_beam_sha256(opts) do
      nil ->
        path = wasm_path(opts)

        case File.stat(path, time: :posix) do
          {:ok, %{size: size, mtime: mtime}} -> {:file, Path.expand(path), size, mtime}
          {:error, _} -> {:file, Path.expand(path), nil, System.unique_integer()}
        end

      sha ->
        {:in_beam, sha}
    end
  end

  @doc """
  Real canonical graph hash of an RDF document (Turtle or N-Triples).

  Returns the hex digest, or a typed error. Note the measured engine
  behaviour documented in `AshA2A.Semantic.Serialize`: `graph_hash/1` does
  **not** report parse errors, so a caller that has not first gated on
  `Serialize.verify/3` cannot distinguish a digest of the intended graph from
  a digest of a silently truncated one.
  """
  @spec graph_hash(binary(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def graph_hash(document, opts \\ []) when is_binary(document),
    do: call_one("graph_hash", [document], opts)

  @doc "Real `blake3_hex/1` of an arbitrary string, straight from the engine."
  @spec blake3_hex(binary(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def blake3_hex(value, opts \\ []) when is_binary(value),
    do: call_one("blake3_hex", [value], opts)

  @doc """
  Real `run_hooks(base_ttl, event_ttl)`, JSON-decoded via
  `AshA2A.Semantic.Serialize.from_json/1`.
  """
  @spec run_hooks(binary(), binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def run_hooks(base, event, opts \\ []) when is_binary(base) and is_binary(event) do
    with({:ok, raw} <- call_one("run_hooks", [base, event], opts), do: Serialize.from_json(raw))
    |> emit_hooks_run(opts)
  end

  # `[:ash_a2a, :semantic, :hooks, :run]`: the knowledge-hook evaluation
  # boundary (RFC-SA2A-002 §12 attempt evidence for the CHI-BRCE hook
  # falsifier). Observational only; hooks are intent, never authority.
  defp emit_hooks_run(result, opts) do
    {outcome, status, code} =
      case result do
        {:ok, %{} = decoded} -> {:evaluated, Map.get(decoded, "status"), nil}
        {:error, %{code: code}} -> {:failed, nil, code}
        _other -> {:failed, nil, nil}
      end

    host =
      case host(opts) do
        {:unavailable, _reason} -> :unavailable
        host -> host
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :hooks, :run],
      %{system_time: System.system_time()},
      %{outcome: outcome, status: status, code: code, host: host}
    )

    result
  end

  @doc """
  Real `validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map)`,
  JSON-decoded via `AshA2A.Semantic.Serialize.from_json/1`.

  All five arguments are RDF/schema *text*; pass `""` for the ones not in play.
  """
  @spec validate_all(binary(), binary(), binary(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def validate_all(ttl, profile \\ "", shacl \\ "", shex \\ "", shape_map \\ "", opts \\ []) do
    with {:ok, raw} <- call_one("validate_all", [ttl, profile, shacl, shex, shape_map], opts),
         do: Serialize.from_json(raw)
  end

  @doc """
  Batched call: `[{"graph_hash", [doc]}, {"blake3_hex", ["abc"]}]`. Returns
  `{:ok, [String.t()]}` (raw engine strings) in the same order.

  On the `:node_shim` host this is one real wasm instantiation. On the
  `:in_beam` host it is one `AshA2A.GraphLaw.WasmexHost.raw_many/3`: every
  call runs inside one host `handle_call/3`, in order, with no interleaving.
  """
  @spec call_many([{String.t(), [binary()]}], keyword()) :: {:ok, [String.t()]} | {:error, map()}
  def call_many(calls, opts \\ []) when is_list(calls) do
    case host(opts) do
      {:unavailable, reason} -> {:error, reason}
      :in_beam -> in_beam_call_many(calls)
      :node_shim -> run_shim(calls, opts)
    end
  end

  @known ~w(graphlaw_version graph_hash blake3_hex run_hooks validate_all)

  defp in_beam_call_many(calls) do
    case Enum.find(calls, fn {fun, _args} -> fun not in @known end) do
      {fun, args} ->
        {:error, %{code: :graphlaw_unknown_function, fn: fun, arity: length(args)}}

      nil ->
        case AshA2A.GraphLaw.WasmexHost.raw_many(calls) do
          {:ok, results} -> {:ok, results}
          {:error, {:invalid_encoding, offset}} -> {:error, invalid_encoding(offset)}
          {:error, _} = error -> error
        end
    end
  end

  defp invalid_encoding(offset),
    do: %{code: :invalid_encoding, byte_offset: offset, detail: "input is not valid UTF-8"}

  defp call_one(fun, args, opts) do
    case call_many([{fun, args}], opts) do
      {:ok, [result]} -> {:ok, result}
      {:ok, other} -> {:error, %{code: :graphlaw_unexpected_result_arity, detail: other}}
      {:error, _} = error -> error
    end
  end

  defp run_shim(calls, opts) do
    payload =
      JSON.encode!(%{
        "calls" => Enum.map(calls, fn {fun, args} -> %{"fn" => fun, "args" => args} end)
      })

    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = System.unique_integer([:positive, :monotonic])
    request_path = Path.join(tmp_dir, "ash_a2a_graphlaw_request_#{unique}.json")
    File.write!(request_path, payload)

    try do
      case AshA2A.GraphLaw.Subprocess.run(
             node_path(opts),
             [shim_path(), wasm_path(opts), request_path],
             opts
           ) do
        {:ok, {stdout, exit_code}} -> decode_shim(stdout, exit_code)
        {:error, _} = error -> error
      end
    after
      File.rm(request_path)
    end
  end

  defp decode_shim(stdout, exit_code) do
    case JSON.decode(stdout) do
      {:ok, %{"ok" => true, "results" => results}} when is_list(results) ->
        {:ok, results}

      {:ok, %{"ok" => false, "error" => detail}} ->
        {:error, %{code: :graphlaw_host_error, detail: detail}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_unexpected_host_payload, detail: other}}

      {:error, reason} ->
        {:error,
         %{code: :graphlaw_non_json_stdout, reason: reason, stdout: stdout, exit_code: exit_code}}
    end
  end

  # An explicit `:wasm_path` opt means the caller cares WHICH wasm bytes
  # execute -- the in-BEAM host runs the one pinned artifact it loaded at
  # start and cannot honour a per-call override, so it is not a truthful
  # answer to that request. Found by a real test asserting a
  # deliberately-wrong `wasm_path:` produces a typed refusal rather than
  # being silently ignored.
  defp in_beam_host?(opts), do: in_beam_sha256(opts) != nil

  defp in_beam_sha256(opts) do
    cond do
      Keyword.has_key?(opts, :wasm_path) ->
        nil

      AshA2A.GraphLaw.WasmexHost.serves?(wasm_path(opts)) ->
        AshA2A.GraphLaw.WasmexHost.loaded_sha256()

      true ->
        nil
    end
  end

  # `System.find_executable/1` walks PATH on every call; a found executable
  # is memoized per requested name (a miss is not, so installing node later
  # is still seen).
  defp find_node(opts) do
    name = node_path(opts)
    key = {__MODULE__, :node, name}

    case :persistent_term.get(key, nil) do
      nil ->
        case System.find_executable(name) do
          nil ->
            nil

          path ->
            :persistent_term.put(key, path)
            path
        end

      path ->
        if File.exists?(path), do: path, else: System.find_executable(name)
    end
  end

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      invalid_encoding: :refused_structure,
      graphlaw_unknown_function: :blocked_resource
    }
end
