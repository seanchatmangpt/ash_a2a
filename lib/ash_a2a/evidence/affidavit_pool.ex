# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Evidence.AffidavitPool do
  @moduledoc """
  The enterprise affidavit pool child (ARD v26.10.4 §2, gate key `:affidavit`,
  `docs/jira/v26.10.4/ARD.md` line 34): a supervised pool of REAL
  `AshAffidavit.Host` WASM engine instances (Wasmtime via `wasmex`) behind one
  name, routed shortest-mailbox-first.

  ## Supervisor integration

  `AshA2A.Enterprise.Supervisor` starts this module when
  `config :ash_a2a, :affidavit` is set, passing the gate value itself as the
  keyword opts (`[wasm_path: String.t(), ...]`); until this module is compiled
  into the release the supervisor logs the typed skip
  `{:module_unavailable, AshA2A.Evidence.AffidavitPool}` and the capability
  is ABSENT. Accepted opts (all optional):

    * `:name` — pool supervisor registered name (default `__MODULE__`).
    * `:size` — pool member count (default: `config :ash_a2a, :affidavit_pool`
      when that key holds a positive integer, else `System.schedulers_online/0`).
    * `:wasm_path`, `:expected_sha256` and every other `AshAffidavit.Host`
      option — passed through to every member; resolution defaults (env var
      `AFFIDAVIT_WASM_PATH`, the vendored engine, the digest pin) are
      `AshAffidavit.WasmConfig`'s own, unchanged.

  ## Fail-closed semantics

  A missing or unloadable engine NEVER fails the start and NEVER crash-loops
  the supervisor: `AshAffidavit.Host` defers the load, answers every request
  with a typed `{:error, %AshAffidavit.Refusal{}}` (`:wasm_not_vendored`,
  `:wasm_unreadable`, `:wasm_invalid`), stays supervised, and retries the
  load in the background. Through this pool's facade the typed refusal
  surfaces with the caller-visible shape `AshA2A.Evidence.Affidavit` already
  returns: `{:error, {:refused_affidavit, refusal}}` (load refusals
  (`:wasm_not_vendored`, `:wasm_unreadable`, `:wasm_invalid`) are class
  `:blocked_resource`, i.e. the `:refused` outcome). When the pool itself is
  not started, `call/3` and the facade return the typed
  `{:error, :pool_not_started}` / `{:error, :ash_affidavit_unavailable}`
  instead of raising.

  ## Facade

  The callers' existing surface (`AshA2A.Evidence.Affidavit.assemble_receipt/1`,
  `verify_receipt/1`, `conform_trace/2`) is mirrored here by delegation:
  a pool member is picked by mailbox length, then the request runs through
  the real `AshAffidavit.call/2` (op registry, three-way outcome mapping,
  authority-NONE guard) with `server:` bound to that member pid. No behavior
  is re-implemented.
  """

  use Supervisor

  alias AshAffidavit.Refusal

  @typedoc "Pool supervisor registered name."
  @type name :: atom()

  @typedoc "Accepted pool options (module doc)."
  @type opts :: [{:name, atom()} | {:size, pos_integer()} | {atom(), term()}]

  @doc """
  Starts the pool. Options in the module doc. An engine load failure never
  fails the start — members become typed refusals until the engine heals.
  """
  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc false
  @impl Supervisor
  def init(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    registry = registry(name)
    host_opts = opts |> Keyword.drop([:size]) |> Keyword.put(:registry, registry)

    members =
      for i <- 0..(size(opts) - 1)//1 do
        Supervisor.child_spec({AshAffidavit.Host, Keyword.merge(host_opts, name: nil)},
          id: {AshAffidavit.Host, i}
        )
      end

    Supervisor.init([{Registry, keys: :duplicate, name: registry} | members],
      strategy: :rest_for_one
    )
  end

  @doc """
  Pool size resolution: `opts[:size]` when positive, else
  `config :ash_a2a, :affidavit_pool` when a positive integer, else
  `System.schedulers_online/0`.
  """
  @spec size(keyword()) :: pos_integer()
  def size(opts \\ []) do
    case Keyword.get(opts, :size) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case Application.get_env(:ash_a2a, :affidavit_pool) do
          n when is_integer(n) and n > 0 -> n
          _ -> System.schedulers_online()
        end
    end
  end

  @doc "The duplicate-key `Registry` this pool's members join."
  @spec registry(atom()) :: atom()
  def registry(name \\ __MODULE__), do: Module.concat(name, Registry)

  @doc "Every live, routable member pid (`AshAffidavit.Pool.members/1` semantics)."
  @spec members(atom()) :: [pid()]
  def members(name \\ __MODULE__), do: AshAffidavit.Pool.members(registry(name))

  @doc "Every member whose engine is currently unavailable (still supervised, retrying)."
  @spec unavailable_members(atom()) :: [pid()]
  def unavailable_members(name \\ __MODULE__) do
    AshAffidavit.Pool.unavailable_members(registry(name))
  end

  @doc """
  True when the `ash_affidavit` engine library is loaded, the pool is started,
  and at least one member has a live, admitted engine. Never raises when the
  pool is down.
  """
  @spec available?(atom()) :: boolean()
  def available?(name \\ __MODULE__) do
    AshA2A.Evidence.Affidavit.available?() and is_pid(Process.whereis(name)) and
      AshAffidavit.Pool.pick(registry(name)) != nil
  end

  @doc "Engine identity of the first live member (`{:ok, %{wasm_sha256: _, ...}}`)."
  @spec info(atom()) :: {:ok, map()} | {:error, term()}
  def info(name \\ __MODULE__) do
    if is_pid(Process.whereis(name)) do
      AshAffidavit.Pool.info(registry(name))
    else
      {:error, Refusal.new(:host_not_started, "pool #{inspect(name)} is not started")}
    end
  end

  @doc """
  Runs one Affidavit request (a string-keyed map carrying `"op"`) through the
  pool: picks the live member with the shortest mailbox, then runs the REAL
  `AshAffidavit.call/2` against that member (same op registry, same four-way
  outcome, same authority-NONE guard as the direct call-in surface).

  Returns `{:error, :ash_affidavit_unavailable}` when the `ash_affidavit`
  engine library is not loaded, and `{:error, :pool_not_started}` when this
  pool is down. Any member's typed refusal
  (`{:refused | :trap | :unsupported, %AshAffidavit.Refusal{}}`) passes
  through verbatim.
  """
  @spec call(name(), map(), keyword()) :: AshAffidavit.result()
  @spec call(map(), keyword()) :: AshAffidavit.result()
  @spec call(name(), map()) :: AshAffidavit.result()
  def call(request, opts \\ [])

  def call(request, opts) when is_map(request) and is_list(opts) do
    call(__MODULE__, request, opts)
  end

  def call(name, request) when is_atom(name) and is_map(request) do
    call(name, request, [])
  end

  def call(name, request, opts) when is_atom(name) and is_map(request) and is_list(opts) do
    if AshA2A.Evidence.Affidavit.available?() do
      live = AshAffidavit.Pool.pick(registry(name))
      members = AshAffidavit.Pool.unavailable_members(registry(name))

      case live || List.first(members) do
        nil -> {:error, :pool_not_started}
        pid -> AshAffidavit.call(request, Keyword.put(opts, :server, pid))
      end
    else
      {:error, :ash_affidavit_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Facade — the exact surface `AshA2A.Evidence.Affidavit` exposes, routed
  # through this pool by delegation. Outcome mapping mirrors affidavit.ex.
  # ---------------------------------------------------------------------------

  @doc "Assembles a certified WASM receipt over a list of lifecycle events, via the pool."
  @spec assemble_receipt(name(), [map()]) :: {:ok, map()} | {:error, term()}
  @spec assemble_receipt([map()]) :: {:ok, map()} | {:error, term()}
  def assemble_receipt(events) when is_list(events), do: assemble_receipt(__MODULE__, events)

  def assemble_receipt(name, events) when is_list(events) do
    case call(name, %{"op" => "assemble", "events" => events}) do
      {:ok, res} -> {:ok, res}
      {:refused, ref} -> {:error, {:refused_affidavit, ref}}
      {:trap, trap} -> {:error, {:affidavit_trap, trap}}
      {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
      {:error, _} = unavailable -> unavailable
    end
  end

  @doc "Verifies an assembled affidavit receipt, via the pool."
  @spec verify_receipt(name(), map() | binary()) :: {:ok, boolean()} | {:error, term()}
  @spec verify_receipt(map() | binary()) :: {:ok, boolean()} | {:error, term()}
  def verify_receipt(receipt), do: verify_receipt(__MODULE__, receipt)

  def verify_receipt(name, receipt) do
    case call(name, %{"op" => "verify", "receipt" => receipt}) do
      {:ok, %{"accepted" => accepted}} -> {:ok, accepted}
      {:refused, ref} -> {:error, {:refused_affidavit, ref}}
      {:trap, trap} -> {:error, {:affidavit_trap, trap}}
      {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
      {:error, _} = unavailable -> unavailable
    end
  end

  @doc "Verifies process model conformance over an event trace, via the pool."
  @spec conform_trace(name(), map(), [map()]) :: {:ok, map()} | {:error, term()}
  @spec conform_trace(map(), [map()]) :: {:ok, map()} | {:error, term()}
  def conform_trace(model, trace), do: conform_trace(__MODULE__, model, trace)

  def conform_trace(name, model, trace) when is_list(trace) do
    case call(name, %{"op" => "conform", "model" => model, "trace" => trace}) do
      {:ok, res} -> {:ok, res}
      {:refused, ref} -> {:error, {:refused_affidavit, ref}}
      {:trap, trap} -> {:error, {:affidavit_trap, trap}}
      {:unsupported, unsup} -> {:error, {:unsupported_affidavit, unsup}}
      {:error, _} = unavailable -> unavailable
    end
  end
end
