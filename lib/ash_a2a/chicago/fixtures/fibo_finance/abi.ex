defmodule AshA2A.Chicago.Fixtures.FiboFinance.Abi do
  @moduledoc """
  Real host for the graphlaw JSON ABI (`gl_alloc` / `gl_call` / `gl_free`)
  compiled to `wasm32-wasip1`, executed by Wasmtime through `wasmex`.

  The module path is read from `GRAPHLAW_ABI_WASM`. There is no default: the
  artifact is a build product of the graphlaw checkout (HEAD-rebuilt; an older
  artifact predates `pre_not` and would admit a replay plan), so a missing or
  unreadable path is `{:error, {:blocked, reason}}` -- never a silent skip.

  The wasm bytes' sha256 is exposed (`sha256/1`) so a court can bind evidence
  to the exact engine build.

  GraphLaw derives and validates; it never authorizes and never actuates.
  """

  use GenServer

  @env "GRAPHLAW_ABI_WASM"

  @doc "Environment variable naming the ABI wasm artifact."
  def env, do: @env

  @doc "Starts a host linked to the caller; a missing artifact is `{:error, {:blocked, reason}}`."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    case Keyword.get(opts, :path) || System.get_env(@env) do
      nil ->
        {:error, {:blocked, "#{@env} is not set"}}

      path ->
        if File.regular?(path),
          do: GenServer.start_link(__MODULE__, path),
          else: {:error, {:blocked, "#{@env}=#{path} is not a readable file"}}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
  catch
    :exit, _ -> :ok
  end

  @doc "sha256 (hex) of the wasm bytes this host runs."
  @spec sha256(pid()) :: String.t()
  def sha256(pid), do: GenServer.call(pid, :sha256)

  @doc "One ABI call: request map in, decoded response map out."
  @spec call(pid(), map()) :: map()
  def call(pid, request) when is_map(request),
    do: GenServer.call(pid, {:call, JSON.encode!(request)}, 120_000) |> JSON.decode!()

  @impl true
  def init(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, pid} <- Wasmex.start_link(%{bytes: bytes, wasi: true}),
         {:ok, store} <- Wasmex.store(pid),
         {:ok, memory} <- Wasmex.memory(pid) do
      _ = Wasmex.call_function(pid, "_initialize", [])

      {:ok,
       %{
         pid: pid,
         store: store,
         memory: memory,
         sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
       }}
    else
      {:error, reason} -> {:stop, {:blocked, "cannot load #{path}: #{inspect(reason)}"}}
    end
  end

  @impl true
  def handle_call(:sha256, _from, state), do: {:reply, state.sha256, state}

  def handle_call({:call, body}, _from, state) do
    {:ok, [ptr]} = Wasmex.call_function(state.pid, "gl_alloc", [byte_size(body)])
    :ok = Wasmex.Memory.write_binary(state.store, state.memory, ptr, body)
    {:ok, [packed]} = Wasmex.call_function(state.pid, "gl_call", [ptr, byte_size(body)])
    out_ptr = Bitwise.bsr(packed, 32)
    out_len = Bitwise.band(packed, 0xFFFF_FFFF)
    out = Wasmex.Memory.read_binary(state.store, state.memory, out_ptr, out_len)
    {:ok, _} = Wasmex.call_function(state.pid, "gl_free", [out_ptr, out_len])
    {:reply, out, state}
  end
end
