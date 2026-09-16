defmodule AshA2A.GraphLaw.RuntimeB do
  @moduledoc """
  Runtime B: a real subprocess wrapper over the native `graphlaw_host` binary,
  which executes the *identical* vendored praxis-graphlaw WebAssembly artifact
  through Wasmtime instead of through any BEAM-embedded wasm runtime.

  ## Why this module exists

  RFC-SA2A-001 v26.9.16 S51 (transport/host independence) only becomes a real
  experiment if two genuinely different hosts execute the *same bytes*. A
  second GraphLaw *implementation* would prove something much weaker (that two
  programs happen to agree); a second *host* over one artifact isolates the
  variable actually under test.

  So this module deliberately contains no semantics of its own. It does not
  parse RDF, canonicalize graphs, or validate anything. Every value it returns
  came out of `priv/graphlaw/praxis_graphlaw_wasm.wasm`, compiled and run by
  Wasmtime inside a process with no BEAM in it at all.

  ## Artifact identity is asserted, not assumed (falsifier #1)

  The native host reports the SHA-256 of the exact `.wasm` bytes it compiled
  with every response. This module independently computes the SHA-256 of the
  file it pointed the host at and **refuses the result** with
  `:wasm_digest_mismatch` if the two disagree. Every successful return
  therefore carries a cross-checked `:wasm_sha256`, which a conformance receipt
  can quote to prove Runtime A and Runtime B ran the same artifact.

  ## Conventions

  Follows `AshA2A.Planning.HddlSolver` exactly: a configurable path to a
  gitignored, must-be-built native binary; a real temporary file on disk; a
  real OS subprocess; the repo's built-in `JSON` module (never `Jason`) to
  decode real stdout; and `{:error, map}` results that always carry a `:code`
  key. Nothing here simulates, stubs, or hand-constructs a GraphLaw answer.

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

  @default_binary Path.expand(
                    "../../../native/graphlaw_host/target/release/graphlaw_host",
                    __DIR__
                  )

  @default_wasm Path.expand("../../../priv/graphlaw/praxis_graphlaw_wasm.wasm", __DIR__)

  @default_timeout 60_000

  @typedoc """
  A successful Runtime B result. `:value` is the raw string the wasm function
  returned; the remaining keys are the artifact/host identity that makes the
  result quotable in a conformance receipt.
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

  @type error :: %{required(:code) => atom(), optional(atom()) => term()}

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
  `:ash_a2a, :graphlaw_wasm_path`, else `priv/graphlaw/praxis_graphlaw_wasm.wasm`.

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
  True iff both the native host binary and the vendored wasm exist on disk, so
  a caller (or a test) can branch on real availability instead of guessing.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    File.exists?(binary_path(opts)) and File.exists?(wasm_path(opts))
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
  def graphlaw_version(opts \\ []), do: call("graphlaw_version", [], opts)

  @doc """
  BLAKE3 hash of a graph's canonical N-Quads form (RFC S12 canonical graph
  identity). Returns the hex digest as `:value`.
  """
  @spec graph_hash(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def graph_hash(ttl, opts \\ []) when is_binary(ttl), do: call("graph_hash", [ttl], opts)

  @doc "BLAKE3 hex digest of arbitrary UTF-8 bytes (no RDF parsing)."
  @spec blake3_hex(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def blake3_hex(data, opts \\ []) when is_binary(data), do: call("blake3_hex", [data], opts)

  @doc """
  Runs GraphLaw hooks over `base_ttl` with the delta `event_ttl`. `:value` is
  the raw JSON string the wasm returned (e.g. `{"status":"ADMITTED",...}`);
  decoding it is the caller's business, since the admission vocabulary belongs
  to the RFC, not to this transport.
  """
  @spec run_hooks(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def run_hooks(base_ttl, event_ttl, opts \\ [])
      when is_binary(base_ttl) and is_binary(event_ttl),
      do: call("run_hooks", [base_ttl, event_ttl], opts)

  @doc """
  Comprehensive validation against all semantic profiles. `:value` is the raw
  JSON string the wasm returned.
  """
  @spec validate_all(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map, opts \\ [])
      when is_binary(ttl) and is_binary(profile_ttl) and is_binary(shacl_shapes) and
             is_binary(shex_schema) and is_binary(shex_shape_map) do
    call("validate_all", [ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map], opts)
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

  defp call(name, args, opts) do
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
        with {:ok, expected_digest} <- wasm_digest(opts),
             {:ok, stdout, status} <- spawn_host(binary, wasm, job, opts),
             {:ok, decoded} <- decode(stdout, status),
             :ok <- assert_digest(decoded, expected_digest) do
          {:ok, decoded, identity(decoded)}
        end
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

  # The whole point of Runtime B: prove, do not assume, that the bytes the
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
