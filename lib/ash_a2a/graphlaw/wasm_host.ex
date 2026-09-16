defmodule AshA2A.GraphLaw.WasmHost do
  @moduledoc """
  Real execution of the vendored GraphLaw `.wasm` artifact.

  This is a real subprocess boundary, exactly the pattern
  `AshA2A.Planning.HddlSolver` already established for the native `hddl_cli`
  binary: write real input, shell out to a real external process, decode its
  real stdout JSON, and return a typed error map (always carrying `:code`) for
  every non-success outcome. No part of this module simulates a GraphLaw
  result -- every `{:ok, _}` this returns came from a real WebAssembly
  instance actually executing.

  The external process is `node` running
  `priv/graphlaw/host/graphlaw_host.mjs`, a dependency-free JS host that
  instantiates the raw module and implements the wasm-bindgen string ABI by
  hand. `node` is a *build/verification-time* requirement (the vendor and
  verify Mix tasks), not a runtime requirement of the library: the committed
  artifact and manifest stay usable without it.

  Every GraphLaw export returns a JSON string and signals failure with an
  `{"error": "..."}` object rather than by trapping, so `call_json/3` checks
  for that key explicitly.
  """

  alias AshA2A.GraphLaw

  @type call :: %{required(:fn) => String.t(), optional(:args) => [String.t()]}
  @type error :: %{required(:code) => atom(), required(:message) => String.t()}

  @doc """
  Returns `{:ok, node_path}` if a usable `node` executable is on `PATH` (or at
  `opts[:node]`), else a typed `{:error, %{code: :node_not_available}}`.

  Exposed separately so callers can degrade to a *named, visible* skip instead
  of silently substituting a fake execution.
  """
  @spec node_executable(keyword()) :: {:ok, String.t()} | {:error, error()}
  def node_executable(opts \\ []) do
    candidate = Keyword.get(opts, :node) || System.get_env("ASH_A2A_NODE") || "node"

    case System.find_executable(candidate) do
      nil ->
        {:error,
         %{
           code: :node_not_available,
           message:
             "no `#{candidate}` executable found on PATH. The GraphLaw wasm host " <>
               "needs Node to execute the vendored artifact. Set ASH_A2A_NODE or " <>
               "pass `node: \"/path/to/node\"`."
         }}

      path ->
        {:ok, path}
    end
  end

  @doc """
  Executes a batch of GraphLaw exports against `wasm_path` in one subprocess.

  `calls` is a list of `%{fn: name, args: [string]}`. Returns
  `{:ok, %{results: [string], exports: [string], imports: [string]}}` where
  `results` is positionally aligned with `calls`.

  Typed errors: `:node_not_available`, `:wasm_not_found`, `:host_not_found`,
  `:host_non_json_stdout`, `:host_failed` (the JS host reported
  `{"ok": false}`; its own `code` is carried through in `:host_code`).
  """
  @spec run([call()], keyword()) :: {:ok, map()} | {:error, error()}
  def run(calls, opts \\ []) when is_list(calls) do
    wasm = Keyword.get(opts, :wasm_path, GraphLaw.wasm_path())
    host = Keyword.get(opts, :host_path, GraphLaw.host_path())

    with {:ok, node} <- node_executable(opts),
         :ok <- exists(wasm, :wasm_not_found, "vendored GraphLaw wasm artifact"),
         :ok <- exists(host, :host_not_found, "GraphLaw JS wasm host") do
      request = JSON.encode!(%{"wasm" => Path.expand(wasm), "calls" => encode_calls(calls)})

      # The request travels through a real temp file rather than stdin because
      # Elixir's `System.cmd/3` has no `:input` option (confirmed: it raises
      # `invalid option :input`). The file is always removed.
      request_path =
        Path.join(
          Keyword.get(opts, :tmp_dir, System.tmp_dir!()),
          "ash_a2a_graphlaw_req_#{System.unique_integer([:positive, :monotonic])}.json"
        )

      File.write!(request_path, request)

      try do
        {stdout, _exit} = System.cmd(node, [host, request_path], stderr_to_stdout: false)
        decode(stdout)
      after
        File.rm(request_path)
      end
    end
  end

  @doc """
  Convenience wrapper for a single export whose result is a JSON document.

  Returns `{:ok, decoded}`, or `{:error, %{code: :graphlaw_error}}` when the
  module reported `{"error": ...}` in-band.
  """
  @spec call_json(String.t(), [String.t()], keyword()) :: {:ok, term()} | {:error, error()}
  def call_json(fun, args \\ [], opts \\ []) when is_binary(fun) and is_list(args) do
    with {:ok, %{results: [raw]}} <- run([%{fn: fun, args: args}], opts) do
      case JSON.decode(raw) do
        {:ok, %{"error" => message}} ->
          {:error, %{code: :graphlaw_error, message: "#{fun}: #{message}"}}

        {:ok, decoded} ->
          {:ok, decoded}

        {:error, reason} ->
          {:error, %{code: :graphlaw_non_json_result, message: "#{fun}: #{inspect(reason)}"}}
      end
    end
  end

  @doc """
  Runs `graphlaw_version/0` and `graph_hash/1` over the three committed
  conformance fixtures, in one subprocess.

  This is the acceptance check the vendor task runs *before* accepting a
  freshly built artifact, and the check `mix ash_a2a.verify_graphlaw` re-runs
  against the committed one. It asserts two real semantic properties, not just
  "it loaded":

    * `base.ttl` and `reordered.ttl` (same graph, different prefix label and
      different triple order) must hash IDENTICALLY -- RFC S12 canonical
      graph identity.
    * `mutated.ttl` (one triple changed) must hash DIFFERENTLY.

  It also checks `blake3_hex("abc")` against the published BLAKE3 test vector,
  which pins the artifact's own hash primitive to a value derived outside this
  repository.
  """
  @spec probe(keyword()) :: {:ok, map()} | {:error, error()}
  def probe(opts \\ []) do
    fixtures = ["base.ttl", "reordered.ttl", "mutated.ttl"]

    with {:ok, bodies} <- read_fixtures(fixtures, opts),
         calls = [
           %{fn: "graphlaw_version", args: []},
           %{fn: "blake3_hex", args: ["abc"]}
           | Enum.map(bodies, &%{fn: "graph_hash", args: [&1]})
         ],
         {:ok, %{results: results, exports: exports, imports: imports}} <- run(calls, opts) do
      [version, blake3_abc, base, reordered, mutated] = results

      {:ok,
       %{
         graphlaw_version: version,
         blake3_abc: blake3_abc,
         blake3_abc_matches_published_vector:
           blake3_abc == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
         graph_hash_base: base,
         graph_hash_reordered: reordered,
         graph_hash_mutated: mutated,
         canonical_order_invariant: base == reordered,
         distinct_graph_distinct_hash: base != mutated,
         exports: exports,
         imports: imports
       }}
    end
  end

  @doc """
  True iff a `probe/1` result satisfies every semantic property the vendor
  pipeline requires of an artifact before accepting it.
  """
  @spec probe_acceptable?(map()) :: boolean()
  def probe_acceptable?(probe) when is_map(probe) do
    probe.canonical_order_invariant and probe.distinct_graph_distinct_hash and
      probe.blake3_abc_matches_published_vector and
      is_binary(probe.graphlaw_version) and probe.graphlaw_version != "" and
      not String.contains?(probe.graph_hash_base, "error")
  end

  @doc """
  Human-readable reasons a `probe/1` result was rejected. Empty list iff
  `probe_acceptable?/1` is true.
  """
  @spec probe_failures(map()) :: [String.t()]
  def probe_failures(probe) when is_map(probe) do
    checks = [
      {probe.canonical_order_invariant,
       "canonical order invariance FAILED: base.ttl and reordered.ttl hashed differently " <>
         "(#{probe.graph_hash_base} vs #{probe.graph_hash_reordered})"},
      {probe.distinct_graph_distinct_hash,
       "graph distinctness FAILED: mutated.ttl hashed identically to base.ttl"},
      {probe.blake3_abc_matches_published_vector,
       "blake3_hex(\"abc\") = #{probe.blake3_abc}, expected the published BLAKE3 test vector"},
      {is_binary(probe.graphlaw_version) and probe.graphlaw_version != "",
       "graphlaw_version() returned no version string"},
      {not String.contains?(probe.graph_hash_base, "error"),
       "graph_hash(base.ttl) returned an in-band error: #{probe.graph_hash_base}"}
    ]

    for {false, reason} <- checks, do: reason
  end

  defp read_fixtures(names, opts) do
    dir = Keyword.get(opts, :fixtures_dir, Path.join(GraphLaw.dir(), "fixtures"))

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      path = Path.join(dir, name)

      case File.read(path) do
        {:ok, body} ->
          {:cont, {:ok, acc ++ [body]}}

        {:error, reason} ->
          {:halt,
           {:error,
            %{
              code: :fixture_not_found,
              message: "cannot read conformance fixture #{path}: #{:file.format_error(reason)}"
            }}}
      end
    end)
  end

  defp encode_calls(calls) do
    Enum.map(calls, fn call ->
      %{"fn" => Map.fetch!(call, :fn), "args" => Map.get(call, :args, [])}
    end)
  end

  defp exists(path, code, label) do
    if File.exists?(path) do
      :ok
    else
      {:error, %{code: code, message: "#{label} not found at #{path}"}}
    end
  end

  defp decode(stdout) do
    case JSON.decode(String.trim(stdout)) do
      {:ok, %{"ok" => true} = payload} ->
        {:ok,
         %{
           results: Map.get(payload, "results", []),
           exports: Map.get(payload, "exports", []),
           imports: Map.get(payload, "imports", [])
         }}

      {:ok, %{"ok" => false} = payload} ->
        {:error,
         %{
           code: :host_failed,
           host_code: Map.get(payload, "code"),
           message: "graphlaw wasm host failed: #{Map.get(payload, "message")}"
         }}

      _ ->
        {:error,
         %{
           code: :host_non_json_stdout,
           message: "graphlaw wasm host produced non-JSON stdout: #{inspect(stdout)}"
         }}
    end
  end
end
