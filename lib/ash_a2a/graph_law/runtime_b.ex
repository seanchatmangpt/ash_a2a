defmodule AshA2A.GraphLaw.RuntimeB do
  @moduledoc """
  Runtime B of the SA2A conformance court: the **out-of-BEAM** WebAssembly
  host.

  Spawns `priv/graphlaw_host/graphlaw_host.mjs` as a real OS subprocess under
  a standalone JavaScript engine and drives it over a real `Port` using
  Erlang's `{:packet, 4}` framing. That subprocess loads the *same*
  `praxis_graphlaw_wasm_bg.wasm` bytes as `AshA2A.GraphLaw.Wasm` and calls
  the same five exported GraphLaw functions over them.

  ## Why this is a real second runtime, and what it is not

  This is a genuinely different host along every axis that the conformance
  claim quantifies over: a different process, a different WebAssembly engine
  implementation (a JIT for a scripting runtime rather than Wasmtime's
  Cranelift), a different memory model, and a hand-written independent
  implementation of the `wasm-bindgen` ABI. If the two disagree on a digest,
  the disagreement is real.

  It is *not* a second implementation of GraphLaw: the WASM module is
  byte-identical, which is exactly the `WASM_A = WASM_B` premise of the
  conformance claim. This court measures **portable execution** of one
  module, never cross-implementation semantic equivalence.

  ## Determinism

  The subprocess supplies the identical deterministic `getRandomValues`
  sequence pinned by `AshA2A.GraphLaw.Runtime.deterministic_random_byte/1`.
  Divergent host entropy would make every downstream digest comparison
  meaningless.
  """

  @behaviour AshA2A.GraphLaw.Runtime

  alias AshA2A.GraphLaw.Runtime

  @script_relative "graphlaw_host/graphlaw_host.mjs"
  @call_timeout 60_000

  @arity %{
    graphlaw_version: 0,
    validate_all: 5,
    graph_hash: 1,
    run_hooks: 2,
    blake3_hex: 1
  }

  @impl true
  def host_id, do: "Node/StandaloneJS"

  @impl true
  def engine_id, do: "v8"

  @impl true
  def available?(opts \\ []) do
    wasm = Runtime.wasm_path(opts)
    script = script_path(opts)

    cond do
      is_nil(executable(opts)) ->
        {:error,
         %{
           code: :graphlaw_host_executable_not_found,
           message:
             "no standalone JS runtime executable found on PATH. Set " <>
               ":graphlaw_runtime_b_executable or GRAPHLAW_HOST_EXECUTABLE."
         }}

      not File.exists?(script) ->
        {:error, %{code: :graphlaw_host_script_not_found, path: script}}

      not File.exists?(wasm) ->
        {:error, %{code: :graphlaw_wasm_not_found, path: wasm}}

      true ->
        :ok
    end
  end

  @impl true
  def open(opts \\ []) do
    with :ok <- available?(opts) do
      exe = executable(opts)
      script = script_path(opts)
      wasm = Runtime.wasm_path(opts)

      port =
        Port.open(
          {:spawn_executable, exe},
          [:binary, :exit_status, :use_stdio, {:packet, 4}, {:args, [script, wasm]}]
        )

      session = %{port: port, counter: :counters.new(1, []), wasm_path: wasm, executable: exe}

      case request(session, %{op: "descriptor"}) do
        {:ok, payload} ->
          case JSON.decode(payload) do
            {:ok, %{"wasm_digest" => digest} = descriptor} ->
              {:ok,
               %{
                 session: Map.put(session, :engine, Map.get(descriptor, "engine", "unknown")),
                 wasm_digest: digest
               }}

            other ->
              close(session)

              {:error,
               %{code: :graphlaw_host_bad_descriptor, payload: payload, decoded: inspect(other)}}
          end

        {:error, reason} ->
          close(session)
          {:error, reason}
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
      request(session, %{op: "call", fn: Atom.to_string(fun), args: args})
    end
  end

  @impl true
  def close(%{port: port} = session) do
    if port_alive?(port) do
      _ = request(session, %{op: "close"})
      if port_alive?(port), do: Port.close(port)
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  The real engine identity string the live subprocess reported for itself
  (e.g. `"v8-14.2.183"`), or `"unknown"` before a session has been opened.
  Reported by the subprocess, never asserted by this module.
  """
  @spec reported_engine(map()) :: String.t()
  def reported_engine(session), do: Map.get(session, :engine, "unknown")

  # -- port protocol --------------------------------------------------------

  defp request(%{port: port, counter: counter} = _session, message) do
    :counters.add(counter, 1, 1)
    id = :counters.get(counter, 1)
    payload = JSON.encode!(Map.put(message, :id, id))

    send(port, {self(), {:command, payload}})

    receive do
      {^port, {:data, data}} ->
        decode_response(data, id)

      {^port, {:exit_status, status}} ->
        {:error, %{code: :graphlaw_host_exited, exit_status: status}}
    after
      @call_timeout ->
        {:error, %{code: :graphlaw_host_timeout, timeout_ms: @call_timeout}}
    end
  catch
    :error, :badarg -> {:error, %{code: :graphlaw_host_port_closed}}
  end

  defp decode_response(data, id) do
    case JSON.decode(data) do
      {:ok, %{"id" => ^id, "ok" => true, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "ok" => false, "error" => error}} ->
        {:error, %{code: :graphlaw_host_error, message: error}}

      {:ok, %{"id" => other}} ->
        {:error, %{code: :graphlaw_host_id_mismatch, expected: id, got: other}}

      {:ok, other} ->
        {:error, %{code: :graphlaw_host_bad_response, response: inspect(other)}}

      {:error, reason} ->
        {:error, %{code: :graphlaw_host_non_json, reason: inspect(reason), raw: data}}
    end
  end

  defp port_alive?(port), do: is_port(port) and not is_nil(Port.info(port))

  defp script_path(opts) do
    Keyword.get(opts, :host_script) ||
      Application.get_env(:ash_a2a, :graphlaw_host_script) ||
      Path.join(:code.priv_dir(:ash_a2a) |> to_string(), @script_relative)
  end

  defp executable(opts) do
    configured =
      Keyword.get(opts, :executable) ||
        Application.get_env(:ash_a2a, :graphlaw_runtime_b_executable) ||
        System.get_env("GRAPHLAW_HOST_EXECUTABLE")

    cond do
      is_binary(configured) and File.exists?(configured) -> configured
      is_binary(configured) -> System.find_executable(configured)
      true -> System.find_executable("node") || System.find_executable("bun")
    end
  end
end
