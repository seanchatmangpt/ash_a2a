defmodule AshA2A.Semantic.RootManifest.EngineProbe do
  @moduledoc """
  Real subprocess probe of the `praxis-graphlaw` semantic engine, scoped to
  exactly what `AshA2A.Semantic.RootManifest` needs: establishing and
  verifying the engine's IDENTITY (its artifact digest and its self-reported
  `graphlaw_version()`), plus the validation/derivation calls
  `AshA2A.Semantic.MetaAdmission` delegates to once an artifact has standing.

  ## This module does no semantics of its own

  Elixir owns envelope, standing, refusal typing, authority, receipts, and
  admission orchestration. It does NOT own canonicalization, SHACL, ShEx,
  Datalog, N3, or SPARQL -- those live in the real Rust engine
  (`praxis-graphlaw`, which self-describes as "native N3, Datalog, SPARQL
  1.1, SHACL, ShEx"). Every verdict this module returns came out of that
  engine; this module is a typed transport across the process boundary and
  nothing more.

  ## Why a Node subprocess rather than an in-BEAM wasm runtime

  The prebuilt `praxis_graphlaw_wasm_bg.wasm` ships with wasm-bindgen
  BUNDLER-target glue, which does not load under a plain host as-is. This
  repo has no in-BEAM wasm runtime dependency, and adding one (a Rustler NIF
  wrapping Wasmtime) is a heavy, separate decision. The established pattern
  in this codebase for calling a native engine is a real `System.cmd/3`
  subprocess decoding real JSON stdout -- `AshA2A.Planning.HddlSolver` does
  exactly this against the real `hddl_cli` binary. This module deliberately
  mirrors that pattern, including its typed `*_not_built`-style fail-closed
  error shape, rather than inventing a second convention.

  `priv/graphlaw/graphlaw_host_probe.mjs` is the committed host: it
  instantiates the same `.wasm` bytes manually against the wasm-bindgen ABI
  and prints one JSON object. It adds no semantics.

  The host speaks an `argv = [op, ...file paths]` protocol with the wasm path
  in the `GRAPHLAW_WASM` environment variable. That is a different protocol
  from `priv/graphlaw/graphlaw_host.mjs` (a JSON request file carrying
  `wasm_path` and a `calls` batch, used by `AshA2A.GraphLaw.Wasm`), so the
  two scripts keep distinct filenames rather than one script speaking both.
  For the same reason the host-script override is
  `:ash_a2a, :graphlaw_probe_host_path`: `:graphlaw_host_path` already names
  the native `graphlaw_host` binary resolved by
  `AshA2A.GraphLaw.WasmtimeRuntime.binary_path/1`.

  ## Resolution order (every path is overridable; nothing is hardcoded-only)

  For each of the wasm artifact, the host script, and the `node` executable:
  `opts` -> `Application.get_env(:ash_a2a, ...)` -> OS environment ->
  a documented default. The wasm lives OUTSIDE this repository (it is a
  build artifact of a sibling Rust workspace, ~3.2MB), so there is no
  in-repo default that resolves on an arbitrary machine -- an unresolvable
  wasm is a real, typed `:graphlaw_wasm_not_available` refusal, never a
  silent pass.

  ## Every failure is typed and fails closed

  No call in this module ever returns a success shape it did not receive
  from the real engine. A missing wasm, a missing host script, a missing
  `node`, non-JSON stdout, or an engine-reported error each return
  `{:error, %{code: ...}}`. There is no "assume valid" branch.
  """

  @default_wasm_path "/Users/sac/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm"
  @host_relative "graphlaw/graphlaw_host_probe.mjs"

  @type failure :: %{required(:code) => atom(), optional(:detail) => term()}

  @doc """
  Resolves the real `praxis-graphlaw` wasm artifact path.

  Order: `opts[:wasm_path]`, `Application.get_env(:ash_a2a,
  :graphlaw_wasm_path)`, `System.get_env("GRAPHLAW_WASM")`, then the
  documented default sibling-workspace path.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path) ||
      System.get_env("GRAPHLAW_WASM") ||
      @default_wasm_path
  end

  @doc """
  Resolves the committed Node host script shipped in this repo's `priv/`.

  Order: `opts[:host_path]`, `Application.get_env(:ash_a2a,
  :graphlaw_probe_host_path)`, then `priv/graphlaw/graphlaw_host_probe.mjs`.
  """
  @spec host_path(keyword()) :: String.t()
  def host_path(opts \\ []) do
    Keyword.get(opts, :host_path) ||
      Application.get_env(:ash_a2a, :graphlaw_probe_host_path) ||
      Path.join(:code.priv_dir(:ash_a2a) |> to_string(), @host_relative)
  end

  @doc "Resolves the `node` executable used to run the host script."
  @spec node_path(keyword()) :: String.t() | nil
  def node_path(opts \\ []) do
    Keyword.get(opts, :node_path) ||
      Application.get_env(:ash_a2a, :graphlaw_node_path) ||
      System.find_executable("node")
  end

  @doc """
  True iff every real prerequisite for an engine call resolves on disk right
  now: the wasm artifact, the host script, and a `node` executable. Purely a
  real filesystem check -- it does not execute the engine.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    node = node_path(opts)

    File.exists?(wasm_path(opts)) and File.exists?(host_path(opts)) and
      is_binary(node) and File.exists?(node)
  end

  @doc """
  The engine's own self-reported version string, obtained by really
  executing `graphlaw_version()` inside the real wasm module.

  Returns e.g. `{:ok, "praxis-graphlaw v26.7.5"}`.
  """
  @spec version(keyword()) :: {:ok, String.t()} | {:error, failure()}
  def version(opts \\ []), do: run("version", [], opts)

  @doc """
  Real RDFC-1.0 canonical graph hash of the Turtle file at `ttl_path`,
  computed by the engine (`graph_hash/1`). This is the canonicalization
  Elixir must never reimplement.
  """
  @spec graph_hash(Path.t(), keyword()) :: {:ok, String.t()} | {:error, failure()}
  def graph_hash(ttl_path, opts \\ []), do: run("graph_hash", [ttl_path], opts)

  @doc """
  Real `validate_all/5`: OWL RL + Datalog + SHACL + ShEx + N3 denial checks
  over the given real files, returning the engine's decoded JSON report.

  `paths` is a keyword list requiring `:data`, `:profile`, `:shapes`,
  `:schema`, and `:shape_map`, each a real path on disk.
  """
  @spec validate_all(keyword(), keyword()) :: {:ok, map()} | {:error, failure()}
  def validate_all(paths, opts \\ []) do
    args = [
      Keyword.fetch!(paths, :data),
      Keyword.fetch!(paths, :profile),
      Keyword.fetch!(paths, :shapes),
      Keyword.fetch!(paths, :schema),
      Keyword.fetch!(paths, :shape_map)
    ]

    with {:ok, json} <- run("validate_all", args, opts), do: decode_engine_json(json)
  end

  @doc """
  Real `run_hooks/2`: applies the N3 rule file at `rules_path` against the
  base graph at `base_path` inside the engine, returning its decoded JSON.
  """
  @spec run_hooks(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, failure()}
  def run_hooks(base_path, rules_path, opts \\ []) do
    with {:ok, json} <- run("run_hooks", [base_path, rules_path], opts),
         do: decode_engine_json(json)
  end

  @doc """
  Executes one real host operation as an OS subprocess and returns the
  engine's raw string result. Every non-success path is a typed refusal.
  """
  @spec run(String.t(), [Path.t()], keyword()) :: {:ok, String.t()} | {:error, failure()}
  def run(op, args, opts \\ []) when is_binary(op) and is_list(args) do
    wasm = wasm_path(opts)
    host = host_path(opts)
    node = node_path(opts)

    cond do
      not File.exists?(wasm) ->
        {:error,
         %{
           code: :graphlaw_wasm_not_available,
           detail:
             "praxis-graphlaw wasm not found at #{wasm}. Set config :ash_a2a, " <>
               ":graphlaw_wasm_path or the GRAPHLAW_WASM env var."
         }}

      not File.exists?(host) ->
        {:error, %{code: :graphlaw_host_not_available, detail: host}}

      not (is_binary(node) and File.exists?(node)) ->
        {:error, %{code: :node_not_available, detail: "no node executable resolved"}}

      true ->
        missing = Enum.reject(args, &File.exists?/1)

        if missing == [] do
          exec(node, host, wasm, op, args)
        else
          {:error, %{code: :engine_input_missing, detail: missing}}
        end
    end
  end

  defp exec(node, host, wasm, op, args) do
    {stdout, exit_code} =
      System.cmd(node, [host, op | args], env: [{"GRAPHLAW_WASM", wasm}], stderr_to_stdout: false)

    case JSON.decode(stdout) do
      {:ok, %{"ok" => true, "result" => result}} ->
        {:ok, result}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, %{code: :graphlaw_host_error, detail: error}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_host_error, detail: other}}

      {:error, _} ->
        {:error,
         %{
           code: :non_json_stdout,
           detail: %{exit_code: exit_code, stdout: String.slice(stdout, 0, 400)}
         }}
    end
  end

  # The engine returns its reports as a JSON STRING inside the host's JSON
  # envelope (it is a String-returning wasm export), so a second decode is
  # real and required -- not redundant wrapping.
  defp decode_engine_json(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        case Map.fetch(decoded, "error") do
          {:ok, error} -> {:error, %{code: :graphlaw_engine_error, detail: error}}
          :error -> {:ok, decoded}
        end

      _ ->
        {:error, %{code: :non_json_engine_result, detail: String.slice(json, 0, 400)}}
    end
  end
end
