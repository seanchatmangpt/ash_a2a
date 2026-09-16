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
  falls back to the in-tree `praxis` checkout location. Absence of the wasm
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

  @default_wasm_path "/Users/sac/praxis/crates/praxis-graphlaw-wasm/pkg/praxis_graphlaw_wasm_bg.wasm"
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

  Runs a real `graphlaw_version` call. Used by tests to decide between
  exercising the engine and asserting the fail-closed path -- never to skip
  silently.
  """
  @spec available?() :: boolean()
  def available?, do: match?({:ok, _}, version())

  @doc "Resolved absolute path of the wasm module this runtime would load."
  @spec wasm_path() :: String.t()
  def wasm_path do
    config(:wasm_path) || System.get_env("GRAPHLAW_WASM") || @default_wasm_path
  end

  @doc "Resolved absolute path of the host shim script."
  @spec host_script() :: String.t()
  def host_script do
    Path.join(:code.priv_dir(:ash_a2a) |> to_string(), "graphlaw/graphlaw_host.mjs")
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
        run(node, script, wasm, fn_name, args)
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
      case System.cmd(node, [script, "--request-file", request_path],
             env: [{"GRAPHLAW_WASM", wasm}],
             stderr_to_stdout: true
           ) do
        {stdout, 0} -> decode_envelope(stdout)
        {stdout, status} -> {:error, refusal(:graphlaw_host_failed, "exit #{status}: #{stdout}")}
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

  # `timeout/0` is resolved but not yet threaded into `System.cmd/3`, which
  # has no timeout option. Documented rather than dropped: a caller wanting a
  # hard bound must wrap the call in a `Task` with `Task.yield/2`.
  @doc false
  def configured_timeout, do: timeout()
end
