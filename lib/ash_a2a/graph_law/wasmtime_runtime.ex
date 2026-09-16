defmodule AshA2A.GraphLaw.WasmtimeRuntime do
  @moduledoc """
  A native, non-BEAM Wasmtime host: a real subprocess wrapper over the
  `native/graphlaw_host` binary, which executes the *identical* vendored
  praxis-graphlaw WebAssembly artifact through Wasmtime instead of through any
  BEAM-embedded wasm runtime.

  This is a third, independent host alongside `AshA2A.GraphLaw.WasmexSession`
  (in-BEAM, `:wasmex`) and `AshA2A.GraphLaw.RuntimeB` (out-of-BEAM, a
  standalone JavaScript engine). It implements the same
  `AshA2A.GraphLaw.Runtime` behaviour, so it can be handed to
  `AshA2A.SA2A.Conformance.run/1` as `:runtime_a` or `:runtime_b`; it is not
  one of the court's defaults.

  ## Why this module exists

  RFC-SA2A-001 v26.9.16 S51 (transport/host independence) only becomes a real
  experiment if two genuinely different hosts execute the *same bytes*. A
  second GraphLaw *implementation* would prove something much weaker (that two
  programs happen to agree); a second *host* over one artifact isolates the
  variable actually under test.

  So this module deliberately contains no semantics of its own. It does not
  parse RDF, canonicalize graphs, or validate anything. Every value it returns
  came out of `priv/graphlaw/praxis_graphlaw.wasm`, compiled and run by
  Wasmtime inside a process with no BEAM in it at all.

  ## Identity

  `{host_id, engine_id}` is `{"Native/graphlaw_host", "wasmtime"}`. That shares
  an *engine* with `AshA2A.GraphLaw.WasmexSession` (`{"BEAM/Wasmex",
  "wasmtime"}`) but not a *host*: one embeds Wasmtime in the BEAM through a
  NIF, this one runs it in a separate OS process with its own hand-written
  `wasm-bindgen` ABI marshalling. The court's identical-runtime refusal is on
  the pair, so the two are admissible against each other; pairing this module
  with `AshA2A.GraphLaw.RuntimeB` varies the engine as well as the host.

  ## Session model

  The native binary answers one JSON job (or one batch of jobs) per process
  and exits, but a `c:AshA2A.GraphLaw.Runtime.open/1` session must behave like
  ONE live wasm instance, because the module is not stateless: measured on
  `priv/sa2a_conformance_vectors/v006_blank_nodes`, repeated `graph_hash/1`
  calls on a blank-node graph inside one instance return a deterministic
  *sequence* of different digests (`dac3b497..`, `725c2598..`, `bb3ebb85..`,
  `47bc5f5f..`), identical under `AshA2A.GraphLaw.WasmexSession` and inside
  one `graphlaw_host` process, while a fresh instance per call returns the
  first digest every time. A fresh-instance-per-call session would therefore
  report a divergence that is an artifact of this wrapper, not of the host.

  So a session records its call sequence (in an `Agent` owned by the session
  and stopped by `close/1`), and each `call/3` runs the *whole* sequence so
  far plus the new call as one batch in one fresh `graphlaw_host` process.
  The new call's result therefore comes from an instance whose state is
  exactly what a persistent instance would hold. Every replayed result is
  compared against the value the session already returned for it; any
  difference is refused as `:graphlaw_session_replay_diverged` rather than
  silently accepted, which also turns host nondeterminism into a checked
  falsifier. The cost is quadratic in session length (one compile per call,
  plus replay), so use `batch/2` directly when session semantics are not
  needed.

  `open/1` runs one real `graphlaw_version` job in its own throwaway process
  to establish the host-reported artifact digest; that probe is not part of
  the session's recorded sequence.

  ## Artifact identity is asserted, not assumed (falsifier #1)

  The native host reports the SHA-256 of the exact `.wasm` bytes it compiled
  with every response. This module independently computes the SHA-256 of the
  file it pointed the host at and **refuses the result** with
  `:wasm_digest_mismatch` if the two disagree. Every successful return
  therefore carries a cross-checked `:wasm_sha256`, which a conformance receipt
  can quote to prove two runtimes ran the same artifact.

  ## Deterministic entropy

  The native host fills `getRandomValues(ptr, len)` with
  `byte(i) = (i * 2654435761) mod 256`, the sequence pinned by
  `AshA2A.GraphLaw.Runtime.deterministic_random_byte/1`.

  ## Conventions

  Follows `AshA2A.Planning.HddlSolver`: a configurable path to a gitignored,
  must-be-built native binary; a real temporary file on disk; a real OS
  subprocess; the repo's built-in `JSON` module (never `Jason`) to decode real
  stdout; and `{:error, map}` results that always carry a `:code` key. Nothing
  here simulates, stubs, or hand-constructs a GraphLaw answer.

  Unlike `HddlSolver` this uses `Port.open/2` rather than `System.cmd/3`,
  because `System.cmd/3` has no timeout. A wasm compile of a ~3.2 MB module is
  seconds-scale work and a wedged host must not wedge the caller, so the
  subprocess runs under a real deadline and is `kill -9`ed on expiry.

  ## Building the binary

  The binary is gitignored (`native/graphlaw_host/.gitignore`), exactly like
  `native/hddl_cli`. Build it with:

      cd native/graphlaw_host && cargo build --release

  Until then every call returns `{:error, %{code: :graphlaw_host_not_built}}`.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  @default_binary Path.expand(
                    "../../../native/graphlaw_host/target/release/graphlaw_host",
                    __DIR__
                  )

  @default_wasm Path.expand("../../../priv/graphlaw/praxis_graphlaw.wasm", __DIR__)

  @default_timeout 60_000

  @arity %{
    graphlaw_version: 0,
    validate_all: 5,
    graph_hash: 1,
    run_hooks: 2,
    blake3_hex: 1
  }

  @typedoc """
  A successful result. `:value` is the raw string the wasm function returned;
  the remaining keys are the artifact/host identity that makes the result
  quotable in a conformance receipt.
  """
  @type result :: %{
          value: String.t(),
          fn: String.t(),
          wasm_sha256: String.t(),
          wasm_bytes: non_neg_integer(),
          runtime: String.t(),
          runtime_version: String.t(),
          host: String.t()
        }

  @type error :: %{required(:code) => atom() | tuple(), optional(atom()) => term()}

  # -- AshA2A.GraphLaw.Runtime ----------------------------------------------

  @impl AshA2A.GraphLaw.Runtime
  def host_id, do: "Native/graphlaw_host"

  @impl AshA2A.GraphLaw.Runtime
  def engine_id, do: "wasmtime"

  @doc """
  `:ok` iff both the native host binary and the vendored wasm exist on disk,
  otherwise the typed refusal naming the absent precondition
  (`:graphlaw_host_not_built` or `:graphlaw_wasm_missing`). Lets a caller (or
  a test) branch on real availability instead of guessing.
  """
  @impl AshA2A.GraphLaw.Runtime
  @spec available?(keyword()) :: :ok | {:error, error()}
  def available?(opts \\ []) do
    binary = binary_path(opts)
    wasm = wasm_path(opts)

    cond do
      not File.exists?(binary) ->
        {:error,
         %{
           code: :graphlaw_host_not_built,
           path: binary,
           message:
             "graphlaw_host binary not built at #{binary}. " <>
               "Run: cd native/graphlaw_host && cargo build --release"
         }}

      not File.exists?(wasm) ->
        {:error,
         %{
           code: :graphlaw_wasm_missing,
           path: wasm,
           message: "vendored GraphLaw wasm not found at #{wasm}"
         }}

      true ->
        :ok
    end
  end

  @doc """
  Opens a session by running one real `graphlaw_version` job through the
  native host. `:wasm_digest` is the SHA-256 the *host* reported for the bytes
  it compiled, already cross-checked against the BEAM-side digest of the same
  file. The session's call sequence starts empty (see "Session model").
  """
  @impl AshA2A.GraphLaw.Runtime
  def open(opts \\ []) do
    with :ok <- available?(opts),
         {:ok, probe} <- run_fn("graphlaw_version", [], opts),
         {:ok, history} <- Agent.start_link(fn -> [] end) do
      {:ok,
       %{
         session: %{
           opts: opts,
           history: history,
           wasm_path: wasm_path(opts),
           binary_path: binary_path(opts),
           wasm_digest: probe.wasm_sha256,
           runtime: probe.runtime,
           runtime_version: probe.runtime_version,
           host: probe.host
         },
         wasm_digest: probe.wasm_sha256
       }}
    end
  end

  @doc """
  Issues one real wasm call against the session's instance state: the recorded
  call sequence plus this call run as one batch in one real native host
  process. Returns the real returned string verbatim.
  """
  @impl AshA2A.GraphLaw.Runtime
  def call(%{opts: opts, history: history}, fun, args) when is_atom(fun) and is_list(args) do
    case Map.fetch(@arity, fun) do
      :error ->
        {:error, %{code: :graphlaw_unsupported_function, function: fun}}

      {:ok, expected} when length(args) != expected ->
        {:error,
         %{code: :graphlaw_arity_mismatch, function: fun, expected: expected, got: length(args)}}

      {:ok, _expected} ->
        session_call(history, {Atom.to_string(fun), args}, opts)
    end
  end

  @doc "Stops the session's call-sequence `Agent`; no host process outlives a call."
  @impl AshA2A.GraphLaw.Runtime
  def close(%{history: history}) do
    Agent.stop(history)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Replays the recorded sequence, checks every replayed outcome against what
  # the session already returned, then records and returns the new outcome.
  defp session_call(history, job, opts) do
    recorded = Agent.get(history, & &1)
    jobs = Enum.map(recorded, fn {recorded_job, _outcome} -> recorded_job end) ++ [job]

    with {:ok, %{results: results}} <- batch(jobs, opts),
         {:ok, replayed, latest} <- split_results(results, length(recorded)),
         :ok <- check_replay(recorded, replayed) do
      Agent.update(history, &(&1 ++ [{job, outcome(latest)}]))

      case latest do
        {:ok, %{value: value}} -> {:ok, value}
        {:error, _} = error -> error
      end
    end
  end

  defp split_results(results, replay_count) when length(results) == replay_count + 1 do
    {replayed, [latest]} = Enum.split(results, replay_count)
    {:ok, replayed, latest}
  end

  defp split_results(results, replay_count) do
    {:error,
     %{
       code: :graphlaw_session_result_count_mismatch,
       expected: replay_count + 1,
       got: length(results)
     }}
  end

  defp outcome({:ok, %{value: value}}), do: {:ok, value}
  defp outcome({:error, %{code: code}}), do: {:error, code}

  defp check_replay(recorded, replayed) do
    recorded
    |> Enum.zip(replayed)
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {{{job, expected}, result}, index} ->
      got = outcome(result)

      if got != expected do
        {fun, _args} = job

        {:error,
         %{
           code: :graphlaw_session_replay_diverged,
           index: index,
           function: fun,
           expected: expected,
           got: got,
           message:
             "replaying this session's call sequence in a fresh graphlaw_host process " <>
               "produced a different outcome than the session already returned; the " <>
               "host is not deterministic over this sequence"
         }}
      end
    end)
  end

  # -- direct API -----------------------------------------------------------

  @doc """
  Resolves the real `graphlaw_host` binary path: `opts[:binary_path]`, else
  `:ash_a2a, :graphlaw_host_path`, else a default computed relative to this
  file. Configurable rather than hardcoded for the same reason as
  `AshA2A.Planning.HddlSolver.cli_path/1`: `native/` is excluded from the
  published hex package, so the computed default only resolves inside a source
  checkout.
  """
  @spec binary_path(keyword()) :: String.t()
  def binary_path(opts \\ []) do
    Keyword.get(opts, :binary_path) ||
      Application.get_env(:ash_a2a, :graphlaw_host_path, @default_binary)
  end

  @doc """
  Resolves the vendored wasm artifact path: `opts[:wasm_path]`, else
  `:ash_a2a, :graphlaw_wasm_path`, else `priv/graphlaw/praxis_graphlaw.wasm`.

  Unlike the binary, the wasm *is* shipped in the hex package (`mix.exs`
  includes `priv`), because the artifact is the thing whose portability is
  under test.
  """
  @spec wasm_path(keyword()) :: String.t()
  def wasm_path(opts \\ []) do
    Keyword.get(opts, :wasm_path) ||
      Application.get_env(:ash_a2a, :graphlaw_wasm_path, @default_wasm)
  end

  @doc """
  SHA-256 (lowercase hex) of the vendored wasm bytes, computed on the BEAM
  side from the real file. This is the value cross-checked against what the
  native host independently reports having compiled.
  """
  @spec wasm_digest(keyword()) :: {:ok, String.t()} | {:error, error()}
  def wasm_digest(opts \\ []) do
    path = wasm_path(opts)

    case File.read(path) do
      {:ok, bytes} -> {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
      {:error, reason} -> {:error, %{code: :graphlaw_wasm_missing, path: path, reason: reason}}
    end
  end

  @doc "Engine version string reported by the wasm module itself."
  @spec graphlaw_version(keyword()) :: {:ok, result()} | {:error, error()}
  def graphlaw_version(opts \\ []), do: run_fn("graphlaw_version", [], opts)

  @doc """
  BLAKE3 hash of a graph's canonical N-Quads form (RFC S12 canonical graph
  identity). Returns the hex digest as `:value`.
  """
  @spec graph_hash(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def graph_hash(ttl, opts \\ []) when is_binary(ttl), do: run_fn("graph_hash", [ttl], opts)

  @doc "BLAKE3 hex digest of arbitrary UTF-8 bytes (no RDF parsing)."
  @spec blake3_hex(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def blake3_hex(data, opts \\ []) when is_binary(data), do: run_fn("blake3_hex", [data], opts)

  @doc """
  Runs GraphLaw hooks over `base_ttl` with the delta `event_ttl`. `:value` is
  the raw JSON string the wasm returned (e.g. `{"status":"ADMITTED",...}`);
  decoding it is the caller's business, since the admission vocabulary belongs
  to the RFC, not to this transport.
  """
  @spec run_hooks(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def run_hooks(base_ttl, event_ttl, opts \\ [])
      when is_binary(base_ttl) and is_binary(event_ttl),
      do: run_fn("run_hooks", [base_ttl, event_ttl], opts)

  @doc """
  Comprehensive validation against all semantic profiles. `:value` is the raw
  JSON string the wasm returned.
  """
  @spec validate_all(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map, opts \\ [])
      when is_binary(ttl) and is_binary(profile_ttl) and is_binary(shacl_shapes) and
             is_binary(shex_schema) and is_binary(shex_shape_map) do
    run_fn("validate_all", [ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map], opts)
  end

  @doc """
  Runs several jobs through a single subprocess, amortizing the (seconds-scale)
  wasm compile across all of them.

  `jobs` is a list of `{function_name, args}` tuples, e.g.
  `[{"graph_hash", [ttl]}, {"blake3_hex", ["abc"]}]`.

  Returns `{:ok, %{results: [{:ok, result()} | {:error, error()}], ...}}` where
  the outer map also carries the cross-checked artifact identity. An outer
  `{:error, _}` means the subprocess or the identity check itself failed, so no
  job result is trustworthy.
  """
  @spec batch([{String.t(), [String.t()]}], keyword()) ::
          {:ok, %{results: [{:ok, result()} | {:error, error()}]}} | {:error, error()}
  def batch(jobs, opts \\ []) when is_list(jobs) do
    encoded = Enum.map(jobs, fn {name, args} -> %{"fn" => name, "args" => args} end)

    with {:ok, decoded, identity} <- invoke(%{"jobs" => encoded}, opts) do
      results =
        decoded
        |> Map.get("results", [])
        |> Enum.map(&job_result(&1, identity))

      {:ok, Map.put(identity, :results, results)}
    end
  end

  # -- internals ------------------------------------------------------------

  defp run_fn(name, args, opts) do
    with {:ok, decoded, identity} <- invoke(%{"fn" => name, "args" => args}, opts) do
      job_result(decoded, identity)
    end
  end

  defp job_result(%{"error" => message} = decoded, identity) do
    {:error,
     identity
     |> Map.merge(%{
       code: decoded_code(decoded),
       message: message,
       fn: decoded["fn"]
     })}
  end

  defp job_result(%{"ok" => value} = decoded, identity) do
    {:ok, Map.merge(identity, %{value: value, fn: decoded["fn"]})}
  end

  defp job_result(other, identity) do
    {:error, Map.merge(identity, %{code: :malformed_result, raw: other})}
  end

  defp decoded_code(%{"code" => code}) when is_binary(code) do
    # Only ever maps host-emitted codes this module already knows; an unknown
    # string stays a string rather than leaking unbounded atom creation.
    case code do
      "bad_job" -> :bad_job
      "bad_arity" -> :bad_arity
      "unsupported_fn" -> :unsupported_fn
      "wasm_call_failed" -> :wasm_call_failed
      "wasm_compile_failed" -> :wasm_compile_failed
      "wasm_instantiation_failed" -> :wasm_instantiation_failed
      "wasm_unreadable" -> :graphlaw_wasm_missing
      "job_file_unreadable" -> :job_file_unreadable
      "non_json_stdin" -> :non_json_stdin
      other -> {:graphlaw_host_error, other}
    end
  end

  defp decoded_code(_), do: :graphlaw_host_error

  defp invoke(job, opts) do
    binary = binary_path(opts)
    wasm = wasm_path(opts)

    with :ok <- available?(opts),
         {:ok, expected_digest} <- wasm_digest(opts),
         {:ok, stdout, status} <- spawn_host(binary, wasm, job, opts),
         {:ok, decoded} <- decode(stdout, status),
         :ok <- assert_digest(decoded, expected_digest) do
      {:ok, decoded, identity(decoded)}
    end
  end

  defp spawn_host(binary, wasm, job, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    unique = System.unique_integer([:positive, :monotonic])
    job_path = Path.join(tmp_dir, "ash_a2a_graphlaw_job_#{unique}.json")

    File.write!(job_path, JSON.encode!(job))

    try do
      port =
        Port.open({:spawn_executable, binary}, [
          :binary,
          :exit_status,
          :hide,
          args: [wasm, job_path]
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      deadline = System.monotonic_time(:millisecond) + timeout
      collect(port, os_pid, deadline, timeout, [])
    after
      File.rm(job_path)
    end
  end

  defp collect(port, os_pid, deadline, timeout, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        collect(port, os_pid, deadline, timeout, [acc, chunk])

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        terminate(port, os_pid)
        {:error, %{code: :timeout, timeout_ms: timeout}}
    end
  end

  defp terminate(port, os_pid) do
    if is_integer(os_pid), do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  defp decode(stdout, status) do
    case JSON.decode(stdout) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, %{code: :malformed_result, raw: other, exit_status: status}}

      {:error, reason} ->
        {:error, %{code: :non_json_stdout, reason: reason, stdout: stdout, exit_status: status}}
    end
  end

  # The whole point of this host: prove, do not assume, that the bytes the
  # non-BEAM host compiled are the bytes this repo vendored.
  defp assert_digest(%{"wasm_sha256" => reported}, expected) when reported == expected, do: :ok

  defp assert_digest(decoded, expected) do
    {:error,
     %{
       code: :wasm_digest_mismatch,
       expected_wasm_sha256: expected,
       reported_wasm_sha256: Map.get(decoded, "wasm_sha256"),
       message:
         "graphlaw_host reported a different wasm digest than the vendored artifact; " <>
           "artifact identity is NOT established and the result must not be used " <>
           "in a conformance receipt"
     }}
  end

  defp identity(decoded) do
    %{
      wasm_sha256: decoded["wasm_sha256"],
      wasm_bytes: decoded["wasm_bytes"],
      runtime: decoded["runtime"],
      runtime_version: decoded["runtime_version"],
      host: decoded["host"]
    }
  end
end
