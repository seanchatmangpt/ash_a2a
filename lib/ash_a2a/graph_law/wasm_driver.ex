defmodule AshA2A.GraphLaw.WasmDriver do
  @moduledoc """
  Real invocation of the prebuilt `praxis-graphlaw` WebAssembly module.

  This is the stdin-driven, batched transport that
  `AshA2A.Semantic.AdmissionHash` and `AshA2A.Semantic.Ontology.canonical_digest/2`
  use for engine graph digests and BLAKE3 digests. It is a sibling of
  `AshA2A.GraphLaw.Wasm` (the `graphlaw_host.mjs` transport behind
  `AshA2A.Semantic.AdmissionPipeline`), not a replacement for it: the two were
  built independently on separate branches, drive different Node scripts and
  expose different result shapes (`call_many/2` returns one
  `{:ok, _} | {:error, _}` per call, `AshA2A.GraphLaw.Wasm.batch/2` returns raw
  strings). Elixir deliberately owns none of the engine semantics: the engine
  (`praxis-graphlaw`, native N3/Datalog/SPARQL/SHACL/ShEx) owns the graph
  digest, and both sides of a portable-conformance comparison must therefore
  execute the *same* wasm bytes. Elixir's job is the envelope, the standing,
  the refusal typing and the receipt -- never the graph algebra.

  The engine's `graph_hash` is prefix- and triple-order-invariant but, as
  measured and pinned in `AshA2A.GraphLaw.Wasm.graph_hash/2` and
  `AshA2A.Semantic.CanonicalDigest`, **not** blank-node-relabel invariant, so
  it is not RDFC-1.0 despite the crate enabling `oxrdf`'s `rdfc-10` feature.

  ## Transport

  The wasm-pack `pkg/` glue shipped alongside the module targets BUNDLER and
  cannot be imported under plain Node ESM, so this module does not use it.
  It instead drives `priv/graphlaw/graphlaw_driver.mjs`, which instantiates
  the raw `praxis_graphlaw_wasm_bg.wasm` directly and reimplements only the
  wasm-bindgen string ABI. Invocation is a real `System.cmd/3` subprocess --
  exactly the pattern `AshA2A.Planning.HddlSolver` already establishes for
  the native HDDL solver. No result this module returns was constructed in
  Elixir; every one came out of the real engine.

  Because instantiating a ~3.2MB module dominates per-call cost, the
  transport is *batched*: `call_many/2` performs any number of engine calls
  inside a single process. `graph_hash/1` and `blake3_hex/1` are
  single-call conveniences over it.

  ## Locating the module

  Resolution order (first hit wins):

    1. `opts[:wasm_path]`
    2. `Application.get_env(:ash_a2a, :graphlaw_wasm_path)`
    3. the `GRAPHLAW_WASM_PATH` environment variable
    4. `AshA2A.GraphLaw.wasm_path/0` -- the vendored, git-tracked,
       MANIFEST-pinned copy at `priv/graphlaw/praxis_graphlaw.wasm`

  The default is the vendored artifact, which every checkout and the published
  package contain, so it resolves without a sibling `praxis` workspace. Every
  function here still returns a typed
  `{:error, %{code: :graphlaw_wasm_not_found, ...}}` rather than raising when
  an explicitly configured path does not resolve.

  ## Error discipline

  The engine's exported functions return `{"error": "..."}` JSON *instead of*
  throwing, so a caller that only checks for an exception will happily treat
  a parse failure as a result. Every function here therefore inspects the
  returned payload and maps an engine-reported error to a typed
  `{:error, map}` with a `:code` key.
  """

  @driver_relative "graphlaw/graphlaw_driver.mjs"

  @type call_spec :: {String.t(), [String.t()]}
  @type error :: %{required(:code) => atom(), optional(atom()) => term()}

  @doc """
  Resolves the absolute path of the `praxis_graphlaw_wasm_bg.wasm` module.

  See the module doc for the resolution order. Returns the path string
  whether or not it exists on disk; use `available?/1` to check.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      System.get_env("GRAPHLAW_WASM_PATH") ||
      AshA2A.GraphLaw.wasm_path()
  end

  @doc """
  Absolute path of the Node driver script shipped in this app's `priv/`.
  """
  @spec driver_path() :: String.t()
  def driver_path do
    case :code.priv_dir(:ash_a2a) do
      {:error, :bad_name} -> Path.expand("../../../priv/#{@driver_relative}", __DIR__)
      dir -> Path.join(to_string(dir), @driver_relative)
    end
  end

  @doc """
  True iff the wasm module, the driver script and a `node` executable are all
  really present. Tests use this to produce a *named, visible skip* rather
  than substituting a fake engine.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    File.exists?(wasm_path(opts)) and File.exists?(driver_path()) and
      System.find_executable("node") != nil
  end

  @doc """
  Runs many engine calls inside one real subprocess.

  `calls` is a list of `{function_name, string_args}`. Returns
  `{:ok, [{:ok, String.t()} | {:error, error}]}` -- one result per call, in
  order -- when the subprocess itself succeeded, or `{:error, error}` when
  the transport failed as a whole (no node, no wasm, non-zero exit,
  undecodable stdout).

      iex> {:ok, [{:ok, v}]} = AshA2A.GraphLaw.WasmDriver.call_many([{"graphlaw_version", []}])
      iex> String.starts_with?(v, "praxis-graphlaw")
      true
  """
  @spec call_many([call_spec()], keyword()) ::
          {:ok, [{:ok, String.t()} | {:error, error()}]} | {:error, error()}
  def call_many(calls, opts \\ []) when is_list(calls) do
    wasm = wasm_path(opts)
    driver = driver_path()

    cond do
      System.find_executable("node") == nil ->
        {:error,
         %{
           code: :graphlaw_node_not_found,
           message: "no `node` executable on PATH; required to drive the graphlaw wasm module"
         }}

      not File.exists?(wasm) ->
        {:error,
         %{
           code: :graphlaw_wasm_not_found,
           path: wasm,
           message:
             "praxis_graphlaw_wasm_bg.wasm not found at #{wasm}. " <>
               "Set config :ash_a2a, :graphlaw_wasm_path or GRAPHLAW_WASM_PATH."
         }}

      not File.exists?(driver) ->
        {:error,
         %{code: :graphlaw_driver_not_found, path: driver, message: "driver script missing"}}

      true ->
        run(wasm, driver, calls, opts)
    end
  end

  defp run(wasm, driver, calls, opts) do
    payload =
      JSON.encode!(%{
        "wasm" => wasm,
        "calls" => Enum.map(calls, fn {fun, args} -> %{"fn" => fun, "args" => args} end)
      })

    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = System.unique_integer([:positive, :monotonic])
    request_path = Path.join(tmp_dir, "ash_a2a_graphlaw_req_#{unique}.json")
    File.write!(request_path, payload)

    try do
      # stdin is fed from a real file rather than an argv string: turtle
      # documents routinely exceed argv limits and contain shell metachars.
      {stdout, exit_code} =
        System.cmd("sh", ["-c", "exec node #{esc(driver)} < #{esc(request_path)}"],
          stderr_to_stdout: false
        )

      decode(stdout, exit_code, length(calls))
    after
      File.rm(request_path)
    end
  end

  defp esc(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp decode(stdout, 0, expected) do
    case JSON.decode(stdout) do
      {:ok, %{"ok" => true, "results" => results}} when is_list(results) ->
        if length(results) == expected do
          {:ok, Enum.map(results, &decode_result/1)}
        else
          {:error,
           %{code: :graphlaw_result_arity_mismatch, expected: expected, got: length(results)}}
        end

      {:ok, %{"ok" => false, "error" => message}} ->
        {:error, %{code: :graphlaw_driver_error, message: message}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_unexpected_payload, payload: other}}

      {:error, _} ->
        {:error, %{code: :graphlaw_non_json_stdout, stdout: String.slice(stdout, 0, 500)}}
    end
  end

  defp decode(stdout, exit_code, _expected) do
    {:error,
     %{
       code: :graphlaw_driver_exit,
       exit_code: exit_code,
       stdout: String.slice(stdout, 0, 500)
     }}
  end

  defp decode_result(%{"ok" => value}) when is_binary(value) do
    # The engine signals failure *in band*, as an {"error": "..."} JSON
    # string return value rather than by throwing. Unwrap it here so callers
    # never mistake an engine error for a digest.
    case JSON.decode(value) do
      {:ok, %{"error" => message}} -> {:error, %{code: :graphlaw_engine_error, message: message}}
      _ -> {:ok, value}
    end
  end

  defp decode_result(%{"error" => message}),
    do: {:error, %{code: :graphlaw_call_error, message: message}}

  defp decode_result(other), do: {:error, %{code: :graphlaw_unexpected_result, result: other}}

  @doc """
  Canonical graph digest of a Turtle document, computed by the engine.

  This is the engine's own normalization, not an Elixir sort-then-hash:
  relabelling prefixes and reordering triples do not change the result,
  while changing a single triple does. It is **not** RDFC-1.0: relabelling
  a blank node changes the digest (measured through this transport,
  `_:b1 ex:p ex:o` -> `e6c028a0...` and `_:zzz9 ex:p ex:o` -> `e5f3cbb0...`,
  byte-identical to `AshA2A.GraphLaw.Wasm.graph_hash/2`, where RDF.ex's
  `RDF.Graph.canonical_hash/1` gives `3105c0b5...` for both).
  """
  @spec graph_hash(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def graph_hash(ttl, opts \\ []) when is_binary(ttl), do: single({"graph_hash", [ttl]}, opts)

  @doc """
  BLAKE3 hex digest of a binary, computed by the engine.

  Deliberately routed through the *same* wasm module that produces
  `graph_hash/2`, so both sides of a conformance comparison agree on one
  BLAKE3 implementation rather than two independently-chosen ones.
  """
  @spec blake3_hex(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def blake3_hex(input, opts \\ []) when is_binary(input),
    do: single({"blake3_hex", [input]}, opts)

  @doc "Engine version string, e.g. `\"praxis-graphlaw v26.7.5\"`."
  @spec version(keyword()) :: {:ok, String.t()} | {:error, error()}
  def version(opts \\ []), do: single({"graphlaw_version", []}, opts)

  defp single(call, opts) do
    case call_many([call], opts) do
      {:ok, [result]} -> result
      {:ok, other} -> {:error, %{code: :graphlaw_result_arity_mismatch, got: other}}
      {:error, _} = error -> error
    end
  end
end
