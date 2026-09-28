defmodule AshA2A.Semantic.GraphLaw.Wasm do
  @moduledoc """
  Real `AshA2A.Semantic.GraphLaw` implementation over the prebuilt
  `praxis-graphlaw` WebAssembly module.

  ## What actually runs

  `priv/graphlaw/graphlaw_host.mjs` is invoked as a real OS subprocess. It
  instantiates `praxis_graphlaw_wasm_bg.wasm` and calls one exported
  function, speaking the wasm-bindgen ABI directly. The wasm is built for
  the wasm-bindgen *bundler* target, so its sibling `.js` glue does not load
  under plain Node ESM; the shim replaces that glue. The module imports
  exactly two host functions (`__wbindgen_object_drop_ref`, a no-op, and
  `__wbg_getRandomValues_*`, a linear-memory fill) and the shim supplies
  both.

  Nothing about the semantics is reimplemented here. This module marshals
  strings in and JSON out.

  ## Configuration

      config :ash_a2a, AshA2A.Semantic.GraphLaw.Wasm,
        wasm_path: "/path/to/praxis_graphlaw_wasm_bg.wasm",
        node: "/opt/homebrew/bin/node",
        timeout: 30_000

  `wasm_path` also reads the `GRAPHLAW_WASM` environment variable, then
  falls back to the vendored, git-tracked, MANIFEST-pinned artifact
  `AshA2A.GraphLaw.wasm_path/0` (`priv/graphlaw/praxis_graphlaw.wasm`). Absence of the wasm
  or of `node` is a typed `:graphlaw_unavailable` refusal, never a silent
  pass.

  ## Per-call instantiation

  Each call instantiates a fresh wasm instance. That is slower than a
  long-lived one and it is the point: a fresh instance carries no residue
  from a previous peer's graph, which is exactly the isolation a cross-peer
  portability claim needs. The engine's own replay check (it runs each
  validation twice against fresh stores and compares hashes) is preserved
  end to end and surfaces as `report["replay"]`.
  """

  @behaviour AshA2A.Semantic.GraphLaw

  alias AshA2A.GraphLaw.Runtime

  @doc false
  def __sa2a_refusal_codes__,
    do: %{
      graphlaw_unavailable: :blocked_resource,
      graphlaw_host_failed: :blocked_resource,
      graphlaw_host_timeout: :blocked_resource,
      graphlaw_host_saturated: :blocked_resource,
      graphlaw_wasm_digest_mismatch: :refused_identity
    }

  @default_timeout 30_000

  @impl true
  def version, do: call("graphlaw_version", [])

  @impl true
  def graph_hash(ttl) when is_binary(ttl) do
    case call("graph_hash", [ttl]) do
      {:ok, "{" <> _ = maybe_error} -> decode_engine_error(maybe_error)
      {:ok, hex} -> {:ok, hex}
      {:error, _} = error -> error
    end
  end

  @impl true
  def validate(ttl, shapes) when is_binary(ttl) and is_binary(shapes) do
    # validate_all(ttl, profile_ttl, shacl_shapes, shex_schema, shex_shape_map)
    with {:ok, json} <- call("validate_all", [ttl, "", shapes, "", ""]),
         {:ok, report} <- decode_json(json) do
      case report do
        %{"error" => detail} -> {:error, refusal(:graphlaw_engine_error, detail)}
        %{} -> {:ok, report}
      end
    end
  end

  @doc """
  Reports whether the real engine is reachable from this runtime right now.

  Cheap (PERF-12): `node`, the wasm and the host shim must exist, and one real
  `graphlaw_version` probe must have succeeded for this wasm file identity
  (`{path, size, mtime}`). The successful probe is memoized in
  `:persistent_term`, so only the first call per artifact spawns `node`; a
  failed probe is not memoized. Used by tests to decide between exercising the
  engine and asserting the fail-closed path -- never to skip silently.
  """
  @spec available?() :: boolean()
  def available? do
    wasm = wasm_path()

    with {:ok, %{size: size, mtime: mtime}} <- File.stat(wasm, time: :posix),
         true <- File.exists?(host_script()) do
      key = {__MODULE__, :probed, Path.expand(wasm), size, mtime}

      case :persistent_term.get(key, nil) do
        node when is_binary(node) ->
          File.exists?(node)

        nil ->
          node = config(:node) || System.find_executable("node")

          is_binary(node) and match?({:ok, _}, version()) and
            :persistent_term.put(key, node) == :ok
      end
    else
      _ -> false
    end
  end

  @doc "Resolved absolute path of the wasm module this runtime would load."
  @spec wasm_path() :: String.t()
  def wasm_path do
    config(:wasm_path) || System.get_env("GRAPHLAW_WASM") || AshA2A.GraphLaw.wasm_path()
  end

  @doc """
  Resolved absolute path of the host shim script.

  Deliberately `graphlaw_host_peer.mjs`, not the shared `graphlaw_host.mjs`:
  a merge reconciliation found `priv/graphlaw/graphlaw_host.mjs` colliding
  between two real, independently-built (caller, script) pairs --
  `AshA2A.GraphLaw.Wasm`'s single-call `{fn, args}`/`GRAPHLAW_WASM`-env-var
  request shape versus this module's own `{wasm_path, calls: [...]}` batch
  shape and `--request-file` argv convention. Neither caller's contract was
  changed; the two scripts instead keep their own distinct filenames so both
  verified pairs keep working unmodified.
  """
  @spec host_script() :: String.t()
  def host_script do
    config(:host_script) ||
      Path.join(:code.priv_dir(:ash_a2a) |> to_string(), "graphlaw/graphlaw_host_peer.mjs")
  end

  defp call(fn_name, args) do
    node = config(:node) || System.find_executable("node")
    wasm = wasm_path()
    script = host_script()

    cond do
      is_nil(node) ->
        {:error, refusal(:graphlaw_unavailable, "no `node` executable on PATH")}

      not File.exists?(wasm) ->
        {:error, refusal(:graphlaw_unavailable, "wasm module not found at #{wasm}")}

      not File.exists?(script) ->
        {:error, refusal(:graphlaw_unavailable, "host shim not found at #{script}")}

      true ->
        with :ok <- check_pin(wasm), do: run(node, script, wasm, fn_name, args)
    end
  end

  @doc """
  SC-04 for the peer transport: `:ok` when the bytes this runtime would hand
  `node` equal the pin, or when the operator named the path itself.

  Pinned: the vendored artifact and any path that arrived only through the
  ambient `GRAPHLAW_WASM` environment variable, against
  `AshA2A.GraphLaw.EngineLoad.expected_sha256/1` (`config :ash_a2a,
  :graphlaw_wasm_sha256`, else the MANIFEST pin). Unpinned: an explicit
  `config :ash_a2a, #{inspect(__MODULE__)}, wasm_path: ...` naming other
  bytes (a court's substituted engine, a local rebuild). Without this, the
  in-BEAM host refusing a swapped `priv` artifact would make
  `AshA2A.Semantic.GraphLaw.impl/1` fall back to this runner, which would
  then execute the same swapped bytes. The file is hashed on every call (a
  few ms against a ~100 ms `node` spawn), so no memo can go stale.
  """
  @spec check_pin(String.t()) :: :ok | {:error, map()}
  def check_pin(wasm) do
    configured = config(:wasm_path)

    expected =
      if is_binary(configured) and Path.expand(configured) == Path.expand(wasm) and
           Path.expand(wasm) != Path.expand(AshA2A.GraphLaw.wasm_path()),
         do: :unpinned,
         else: AshA2A.GraphLaw.EngineLoad.expected_sha256([])

    with {:ok, bytes} <- File.read(wasm),
         :ok <- AshA2A.GraphLaw.EngineLoad.check_digest(Runtime.bytes_digest(bytes), expected) do
      :ok
    else
      {:error, %{code: code} = error} ->
        {:error, refusal(code, inspect(Map.delete(error, :code)))}

      {:error, reason} ->
        {:error,
         refusal(:graphlaw_unavailable, "wasm module unreadable at #{wasm}: #{inspect(reason)}")}
    end
  end

  defp run(node, script, wasm, fn_name, args) do
    request = Jason.encode!(%{"fn" => fn_name, "args" => args})
    request_path = Path.join(System.tmp_dir!(), "ash_a2a_graphlaw_#{unique()}.json")

    try do
      File.write!(request_path, request)

      # Request goes via a real temp file rather than stdin: `System.cmd/3`
      # has no stdin plumbing, and graphs are routinely larger than an argv
      # slot can hold.
      # stderr is NOT merged into stdout (PERF-12): a node warning on stderr
      # must not turn a successful envelope into a JSON decode failure.
      case AshA2A.GraphLaw.Subprocess.run(node, [script, "--request-file", request_path],
             env: [{"GRAPHLAW_WASM", wasm}],
             timeout_ms: timeout()
           ) do
        {:ok, {stdout, 0}} ->
          decode_envelope(stdout)

        {:ok, {stdout, status}} ->
          {:error, refusal(:graphlaw_host_failed, "exit #{status}: #{stdout}")}

        {:error, %{code: code} = error} ->
          {:error, refusal(code, inspect(Map.delete(error, :code)))}
      end
    rescue
      error -> {:error, refusal(:graphlaw_host_failed, Exception.message(error))}
    after
      File.rm(request_path)
    end
  end

  defp decode_envelope(stdout) do
    case decode_json(String.trim(stdout)) do
      {:ok, %{"ok" => true, "result" => result}} ->
        {:ok, result}

      {:ok, %{"ok" => false, "error" => detail}} ->
        {:error, refusal(:graphlaw_call_failed, detail)}

      {:ok, other} ->
        {:error, refusal(:graphlaw_call_failed, "unexpected envelope #{inspect(other)}")}

      {:error, _} = error ->
        error
    end
  end

  defp decode_engine_error(json) do
    case decode_json(json) do
      {:ok, %{"error" => detail}} -> {:error, refusal(:graphlaw_engine_error, detail)}
      {:ok, _} -> {:error, refusal(:graphlaw_engine_error, json)}
      {:error, _} = error -> error
    end
  end

  defp decode_json(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, refusal(:graphlaw_bad_response, Exception.message(error))}
    end
  end

  defp config(key) do
    :ash_a2a
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end

  defp timeout, do: config(:timeout) || @default_timeout

  defp unique, do: "#{System.unique_integer([:positive])}_#{:erlang.phash2(self(), 1_000_000)}"

  defp refusal(code, detail), do: %{code: code, detail: to_string(detail)}

  # `timeout/0` bounds every subprocess through `AshA2A.GraphLaw.Subprocess`
  # (a timed-out node is killed: `:graphlaw_host_timeout`).
  @doc false
  def configured_timeout, do: timeout()
end
