defmodule AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect do
  @moduledoc """
  External-domain ledger for the `SA2A-CHAOS` court (RFC-SA2A-002 §70, §71,
  §96).

  Every `:apply_effect` inserts one real row keyed by the caller's
  `operation_id` (the SA2A actuation identity). The ledger deliberately does
  NOT deduplicate: idempotency must come from the SA2A boundary, so a second
  consequence for one command id is visible as a second row to an independent
  `Ash.read!/2`. Rows live in a shared (non-private) ETS table owned by Ash's
  table manager, so they survive the death of the process that wrote them --
  the external system outlives a crashed caller.

  Environment knobs (they shape the external system, never the SUT):

    * `hang_before_ms` -- the external call stalls before applying (actuator
      timeout: the caller gives up while no effect exists yet)
    * `hang_after_ms` -- the external call stalls after applying (crash
      during the external call with the effect already durable)
    * `fail` -- the external system rejects the call (no row)
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.ChaosReconciliation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  require Ash.Query

  attributes do
    uuid_primary_key(:id)
    attribute(:operation_id, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy])

    create :record do
      accept([:operation_id])
    end

    action :apply_effect, :string do
      argument(:operation_id, :string, allow_nil?: false)
      argument(:hang_before_ms, :integer, allow_nil?: false, default: 0)
      argument(:hang_after_ms, :integer, allow_nil?: false, default: 0)
      argument(:fail, :boolean, allow_nil?: false, default: false)

      run(fn input, _context ->
        AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.apply_effect(input.arguments)
      end)
    end

    action :compensate_effect, :integer do
      argument(:operation_id, :string, allow_nil?: false)

      run(fn input, _context ->
        rows =
          AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect.rows(input.arguments.operation_id)

        Enum.each(rows, &Ash.destroy!/1)
        {:ok, length(rows)}
      end)
    end
  end

  a2a do
    skill(:apply_effect, :apply_effect, consequence: :external_do)
    skill(:compensate_effect, :compensate_effect, consequence: :external_do)
  end

  @doc "Independent read of the ledger rows for one actuation identity."
  @spec rows(String.t()) :: [Ash.Resource.record()]
  def rows(operation_id) when is_binary(operation_id) do
    __MODULE__
    |> Ash.Query.filter(operation_id == ^operation_id)
    |> Ash.read!()
  end

  @doc false
  def apply_effect(args) do
    stall(Map.get(args, :hang_before_ms, 0))

    if Map.get(args, :fail, false) do
      {:error, "external system rejected operation #{args.operation_id}"}
    else
      __MODULE__
      |> Ash.Changeset.for_create(:record, %{operation_id: args.operation_id})
      |> Ash.create!()

      stall(Map.get(args, :hang_after_ms, 0))
      {:ok, args.operation_id}
    end
  end

  defp stall(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp stall(_), do: :ok
end

defmodule AshA2A.Chicago.Fixtures.ChaosReconciliation.Domain do
  @moduledoc "Ash domain for the `SA2A-CHAOS` external-domain ledger."
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect)
  end
end

defmodule AshA2A.Chicago.Fixtures.ChaosReconciliation.Environment do
  @moduledoc """
  Real fault-injection environment for the `SA2A-CHAOS` court (RFC-SA2A-002
  §10: fault injection changes the environment around a real component, it
  never replaces the component under qualification).

  One environment = one isolated, real durability stack:

    * a real on-disk `EKV` instance (`cluster_size: 1`) serving the real
      `AshA2A.ReceiptStore.Ekv` primary store, under its own data dir;
    * a dedicated real `AshA2A.ReceiptOutbox` directory
      (`:receipt_outbox_dir`, restored on `close/1`).

  Faults it injects:

    * `crash_store/1` -- brutally kills the EKV supervision tree (no graceful
      shutdown); `restart_store/1` starts a fresh EKV over the same data dir
      (a real restart: the new instance only knows what reached disk).
    * `run_crashing/4` -- runs the real `AshA2A.CommandBus.run/4` in a
      spawned process and kills it with the untrappable `:kill` reason at a
      real CommandBus boundary telemetry event, inside the external call, or
      after an actuator timeout.
    * `run_paused/5` -- holds the real executing process at a boundary while
      the environment changes underneath it (concurrent reconciliation,
      storage loss), then lets it continue.

  Crash handlers run in the emitting SUT process. `:telemetry` dispatches
  handlers in attach order on the ETS handler table; the observer attaches
  before any court runs, so it records the boundary event before the crash
  handler kills the process. `attach_ordered?/0` verifies that property on
  the live telemetry implementation; courts must not inject boundary crashes
  when it does not hold.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt}
  alias AshA2A.Chicago.Fixtures.ChaosReconciliation.Effect
  alias AshA2A.ReceiptStore.Ekv

  defstruct [:root, :outbox_dir, :data_dir, :ekv_name, :previous_outbox_dir]

  @type t :: %__MODULE__{}

  @principal "sa2a-chaos-subject"
  @agent "sa2a-chaos-agent"

  @doc "Opens an isolated environment under `root` and starts its EKV store."
  @spec open(Path.t()) :: t()
  def open(root) do
    unique = System.unique_integer([:positive])
    root = Path.join(root, "env-#{unique}")

    env = %__MODULE__{
      root: root,
      outbox_dir: Path.join(root, "outbox"),
      data_dir: Path.join(root, "ekv"),
      ekv_name: :"sa2a_chaos_ekv_#{unique}",
      previous_outbox_dir: Application.get_env(:ash_a2a, :receipt_outbox_dir)
    }

    File.mkdir_p!(env.outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, env.outbox_dir)
    restart_store(env)
  end

  @doc "Stops the store, restores the outbox directory, removes the EKV data dir."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = env) do
    _ = crash_store(env)

    case env.previous_outbox_dir do
      nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
      dir -> Application.put_env(:ash_a2a, :receipt_outbox_dir, dir)
    end

    File.rm_rf(env.data_dir)
    :ok
  end

  @spec store() :: module()
  def store, do: Ekv

  @spec store_opts(t()) :: keyword()
  def store_opts(%__MODULE__{ekv_name: name}), do: [name: name]

  @doc """
  Kills the EKV supervision tree with the untrappable `:kill` reason (no
  graceful shutdown) and waits until its registered names are released.
  """
  @spec crash_store(t()) :: t()
  def crash_store(%__MODULE__{} = env) do
    case Process.whereis(sup_name(env)) do
      nil -> :ok
      sup -> kill_and_wait(sup)
    end

    # The tree's registered workers die asynchronously after the supervisor;
    # a restart before every name is released would collide with them.
    wait_until(fn -> registered_names(env) == [] end, 10_000)
    env
  end

  defp registered_names(%__MODULE__{ekv_name: name}) do
    prefix = Atom.to_string(name) <> "_"
    Enum.filter(Process.registered(), &String.starts_with?(Atom.to_string(&1), prefix))
  end

  @doc "True while the environment's EKV store is running."
  @spec store_alive?(t()) :: boolean()
  def store_alive?(%__MODULE__{} = env), do: Process.whereis(sup_name(env)) != nil

  @doc """
  Crashes (if running) and starts EKV again over the same data dir: the new
  instance only knows what reached disk.
  """
  @spec restart_store(t()) :: t()
  def restart_store(%__MODULE__{} = env) do
    env = crash_store(env)

    {:ok, sup} =
      EKV.start_link(name: env.ekv_name, data_dir: env.data_dir, cluster_size: 1)

    Process.unlink(sup)
    env
  end

  defp sup_name(%__MODULE__{ekv_name: name}), do: :"#{name}_ekv_sup"

  # --- SUT inputs ---------------------------------------------------------------

  @spec capability(atom()) :: String.t()
  def capability(action \\ :apply_effect), do: "#{inspect(Effect)}.#{action}"

  @doc "A real consequence-bearing command with a matching authority."
  @spec command(String.t(), map(), atom()) :: Command.t()
  def command(command_id, input, action \\ :apply_effect) do
    principal = Identity.principal(@principal)
    capability = capability(action)

    Command.new(capability,
      command_id: command_id,
      agent_id: @agent,
      principal_id: principal,
      authority: Authority.new(principal, capability, token_id: "sa2a-chaos-" <> command_id),
      input: input
    )
  end

  @spec message(map()) :: A2A.Message.t()
  def message(input), do: A2A.Message.new_user([A2A.Part.Data.new(input)])

  @doc "One real `CommandBus.run/4` against this environment's durable stores."
  @spec run(t(), String.t(), map(), atom()) :: CommandBus.result()
  def run(%__MODULE__{} = env, command_id, input, action \\ :apply_effect) do
    CommandBus.run(command(command_id, input, action), message(input), Effect,
      store: Ekv,
      store_opts: store_opts(env)
    )
  end

  @doc "External-domain rows for one actuation identity (independent reader)."
  @spec rows(String.t()) :: non_neg_integer()
  def rows(operation_id), do: length(Effect.rows(operation_id))

  @doc """
  External-domain outcome probe for `AshA2A.Reconciliation.reconcile/4`: reads
  the ledger by the receipt's actuation identity; never actuates.
  """
  @spec probe(Receipt.t()) :: AshA2A.Reconciliation.probe_result()
  def probe(%Receipt{command_id: %Identity{value: operation_id}}) do
    case rows(operation_id) do
      0 -> {:not_executed, %{"ledger_rows" => 0}}
      n -> {:executed, %{"ledger_rows" => n}}
    end
  end

  @doc """
  Raw durable evidence for one command, read without `AshA2A.Reconciliation`
  or `AshA2A.ReceiptOutbox` (independent post-state reader): the journal files
  on disk and the EKV entry exactly as stored.

  `outbox_files` counts every `*.receipt` file; `outbox_statuses` lists the
  statuses of decodable files belonging to this command; `primary` is
  `:absent`, `:unavailable`, `:claimed` (claim without receipt) or the stored
  receipt's `%{status, outcome}`.
  """
  @spec raw_evidence(t(), String.t()) :: map()
  def raw_evidence(%__MODULE__{} = env, command_id) do
    files =
      case File.ls(env.outbox_dir) do
        {:ok, names} -> Enum.filter(names, &String.ends_with?(&1, ".receipt"))
        _ -> []
      end

    statuses =
      Enum.flat_map(files, fn name ->
        with {:ok, bin} <- File.read(Path.join(env.outbox_dir, name)),
             {:ok, {_v, %Receipt{command_id: %Identity{value: ^command_id}} = r}} <- decode(bin) do
          [r.status]
        else
          _ -> []
        end
      end)

    primary =
      try do
        case EKV.get(env.ekv_name, "command:" <> command_id) do
          nil -> :absent
          %{receipt: %Receipt{} = r} -> %{status: r.status, outcome: r.metadata[:outcome]}
          %{} -> :claimed
        end
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

    %{outbox_files: length(files), outbox_statuses: statuses, primary: primary}
  end

  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    _ -> :error
  end

  @doc "Truncates every journal file to half its bytes (a torn/partial write). Returns the count."
  @spec tear_outbox_entries(t()) :: non_neg_integer()
  def tear_outbox_entries(%__MODULE__{} = env) do
    case File.ls(env.outbox_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".receipt"))
        |> Enum.count(fn name ->
          path = Path.join(env.outbox_dir, name)
          bin = File.read!(path)
          File.write!(path, binary_part(bin, 0, div(byte_size(bin), 2)), [:binary, :sync])
          true
        end)

      _ ->
        0
    end
  end

  # --- fault injection ------------------------------------------------------------

  @doc """
  Runs the command in a spawned process and crashes it. `crash` is one of:

    * `{:at_event, event, metadata_match}` -- kill inside the SUT process at
      the first matching CommandBus boundary telemetry event
    * `:during_external_call` -- kill once the external effect row exists
      while the external call is still in progress (input must stall with
      `hang_after_ms`)
    * `{:actuator_timeout, ms}` -- kill `ms` after actuation started (input
      must stall with `hang_before_ms`)

  Returns `%{crash_point_reached?, down_reason, returned}`; `returned` is the
  bus reply if the process returned instead of crashing.
  """
  @spec run_crashing(t(), String.t(), map(), term()) :: map()
  def run_crashing(%__MODULE__{} = env, command_id, input, crash) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          {:go, ^ref} -> :ok
        end

        send(parent, {:returned, ref, run(env, command_id, input)})
      end)

    monitor = Process.monitor(pid)
    handler = {__MODULE__, :crash, ref}

    try do
      attach_crash(handler, crash, %{target: pid, parent: parent, ref: ref})
      send(pid, {:go, ref})
      reached? = await_crash_point(crash, {pid, monitor}, ref, command_id)
      down = await_down(monitor, pid, 15_000)

      %{
        crash_point_reached?: reached? and down == :killed,
        down_reason: down,
        returned: receive_returned(ref)
      }
    after
      :telemetry.detach(handler)
    end
  end

  defp attach_crash(handler, {:at_event, event, match}, config) do
    :ok =
      :telemetry.attach(
        handler,
        event,
        &__MODULE__.handle_crash_event/4,
        Map.put(config, :match, match)
      )
  end

  defp attach_crash(handler, {:actuator_timeout, _ms}, config) do
    :ok =
      :telemetry.attach(
        handler,
        [:ash_a2a, :command_bus, :actuate, :start],
        &__MODULE__.handle_latch_event/4,
        config
      )
  end

  defp attach_crash(_handler, :during_external_call, _config), do: :ok

  defp await_crash_point({:at_event, _event, _match}, {pid, monitor}, ref, _command_id) do
    receive do
      {:crash_point, ^ref} -> true
      {:DOWN, ^monitor, :process, ^pid, _} = down -> requeue(down)
    after
      15_000 -> false
    end
  end

  defp await_crash_point({:actuator_timeout, ms}, {pid, monitor}, ref, _command_id) do
    receive do
      {:latched, ^ref} ->
        Process.sleep(ms)
        Process.exit(pid, :kill)
        true

      {:DOWN, ^monitor, :process, ^pid, _} = down ->
        requeue(down)
    after
      15_000 -> false
    end
  end

  defp await_crash_point(:during_external_call, {pid, _monitor}, _ref, command_id) do
    applied? =
      wait_until(fn -> rows(command_id) > 0 or not Process.alive?(pid) end, 15_000) and
        rows(command_id) > 0

    if applied? and Process.alive?(pid) do
      Process.exit(pid, :kill)
      true
    else
      false
    end
  end

  # The SUT process ended before the crash point: not reached; keep the DOWN
  # message for `await_down/3`.
  defp requeue(message) do
    send(self(), message)
    false
  end

  @doc """
  Runs the command in a spawned process, holds it at the first matching
  `event` emitted by that process, runs `while_paused` in the caller, then
  resumes it. Returns `%{paused?, while_paused, returned, down_reason}`.
  """
  @spec run_paused(t(), String.t(), map(), [atom()], (-> term())) :: map()
  def run_paused(%__MODULE__{} = env, command_id, input, event, while_paused) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          {:go, ^ref} -> :ok
        end

        send(parent, {:returned, ref, run(env, command_id, input)})
      end)

    monitor = Process.monitor(pid)
    handler = {__MODULE__, :pause, ref}

    try do
      :ok =
        :telemetry.attach(handler, event, &__MODULE__.handle_pause_event/4, %{
          target: pid,
          parent: parent,
          ref: ref
        })

      send(pid, {:go, ref})

      receive do
        {:paused, ^ref} ->
          value = while_paused.()
          send(pid, {:resume, ref})
          down = await_down(monitor, pid, 15_000)

          %{
            paused?: true,
            while_paused: value,
            returned: receive_returned(ref),
            down_reason: down
          }
      after
        15_000 ->
          Process.exit(pid, :kill)
          %{paused?: false, while_paused: nil, returned: nil, down_reason: :timeout}
      end
    after
      :telemetry.detach(handler)
    end
  end

  @doc """
  Attaches `handler_fun` to kill the environment's store from inside the SUT
  process at the first matching `event` (storage loss mid-run). Returns the
  handler id; detach with `:telemetry.detach/1`.
  """
  @spec attach_store_crash(t(), [atom()], map()) :: term()
  def attach_store_crash(%__MODULE__{} = env, event, match) do
    handler = {__MODULE__, :store_crash, make_ref()}

    :ok =
      :telemetry.attach(handler, event, &__MODULE__.handle_store_crash_event/4, %{
        env: env,
        match: match,
        fired: :counters.new(1, [:write_concurrency])
      })

    handler
  end

  # --- telemetry handlers (run in the emitting SUT process) --------------------

  @doc false
  def handle_crash_event(_event, _measurements, metadata, %{target: target} = config) do
    if self() == target and matches?(metadata, config.match) do
      send(config.parent, {:crash_point, config.ref})
      Process.exit(self(), :kill)
    end

    :ok
  end

  @doc false
  def handle_latch_event(_event, _measurements, _metadata, %{target: target} = config) do
    if self() == target, do: send(config.parent, {:latched, config.ref})
    :ok
  end

  @doc false
  def handle_pause_event(_event, _measurements, _metadata, %{target: target} = config) do
    if self() == target and Process.get({__MODULE__, :paused, config.ref}) == nil do
      Process.put({__MODULE__, :paused, config.ref}, true)
      send(config.parent, {:paused, config.ref})

      receive do
        {:resume, ref} when ref == config.ref -> :ok
      after
        30_000 -> :ok
      end
    end

    :ok
  end

  @doc false
  def handle_store_crash_event(_event, _measurements, metadata, config) do
    if :counters.get(config.fired, 1) == 0 and matches?(metadata, config.match) do
      :counters.add(config.fired, 1, 1)
      crash_store(config.env)
    end

    :ok
  end

  @doc """
  True when `:telemetry` dispatches handlers of one event in attach order on
  this node -- the property that lets a boundary crash handler run after the
  already-attached observer has recorded the boundary event.
  """
  @spec attach_ordered?() :: boolean()
  def attach_ordered? do
    event = [:ash_a2a, :chicago, :chaos, :order_probe]
    probe = make_ref()
    ids = for n <- 1..3, do: {__MODULE__, :order_probe, n, probe}

    try do
      for {id, n} <- Enum.with_index(ids, 1) do
        :ok =
          :telemetry.attach(id, event, &__MODULE__.handle_order_probe/4, %{
            n: n,
            to: self(),
            probe: probe
          })
      end

      :telemetry.execute(event, %{}, %{probe: probe})

      order =
        for _ <- ids do
          receive do
            {:order_probe, ^probe, n} -> n
          after
            1_000 -> nil
          end
        end

      order == [1, 2, 3]
    after
      Enum.each(ids, &:telemetry.detach/1)
    end
  end

  @doc false
  def handle_order_probe(_event, _m, %{probe: probe}, %{n: n, to: to, probe: probe}),
    do: send(to, {:order_probe, probe, n})

  def handle_order_probe(_event, _m, _meta, _config), do: :ok

  # --- utilities --------------------------------------------------------------------

  @doc "Polls `fun` every 2ms until it returns true or `timeout_ms` elapses."
  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  def wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(2)
        do_wait_until(fun, deadline)
    end
  end

  defp matches?(metadata, match),
    do: Enum.all?(match, fn {key, value} -> Map.get(metadata, key) == value end)

  defp kill_and_wait(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp await_down(monitor, pid, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} -> reason
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :timeout
        end
    end
  end

  defp receive_returned(ref) do
    receive do
      {:returned, ^ref, value} -> value
    after
      0 -> nil
    end
  end
end
