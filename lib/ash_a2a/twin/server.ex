defmodule AshA2A.Twin.Server do
  @moduledoc """
  Shared `gen_statem` engine for the twin actors
  (`AshA2A.Twin.{Asset,Partner,Operator}` dispatch on their `kind`).

  Each twin runs under a `DynamicSupervisor` started by `AshA2A.Twin`,
  keeps local state in-memory only (no store dependency), and emits typed
  events to a configured listener pid:

  - Asset: `{:sla_expired, name, meta}` when the SLA countdown fires
  - Partner: `{:hazard_tripped, name, z, stats}` on an unacknowledged
    outstanding dispatch crossing the threshold, and
    `{:shift_changed, name, shift}` on shift flips
  - Operator: `{:budget_exhausted, name, meta}` when the attention budget hits 0

  Clock injection (`clock: {:mono, fun}`) is honored for timer arithmetic so
  tests never sleep for synchronization.
  """

  @behaviour :gen_statem

  alias AshA2A.Twin.Hazard

  @typedoc "Twin kind."
  @type kind :: :asset | :partner | :operator

  # -- public API (called via the wrapper twin modules) ---------------------

  @doc """
  Start a twin under the caller's DynamicSupervisor.

  KNOWN RUNTIME DIVERGENCE (OTP 28.3.1 erlmcp build): `:gen_statem.start_link/3`
  silently drops ALL `name:` registration forms (local atom, `:global`,
  `:via`) — the process starts alive and unregistered. GenServer registration
  is unaffected. Workaround: start unnamed and register manually after the
  start ack. Caveat: a restarted twin (post-crash) re-enters without its
  name; `AshA2A.Twin.Registry` holds {name -> pid} as the recoverable index
  but auto-restart re-registration is not implemented in this lane.
  """
  @spec start_link(kind(), atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(kind, name, opts) when kind in [:asset, :partner, :operator] do
    with {:ok, pid} <- :gen_statem.start_link(__MODULE__, {name, kind, opts}, []) do
      case Process.whereis(name) do
        nil ->
          true = :erlang.register(name, pid)
          Registry.register(AshA2A.Twin.Registry, name, pid)
          {:ok, pid}

        _existing ->
          {:error, {name, :already_registered}}
      end
    end
  end

  @doc "Synchronous status snapshot."
  @spec status(atom()) :: map()
  def status(name), do: :gen_statem.call(name, :status)

  @doc "Synchronous call to the twin (peek-style queries)."
  @spec call(atom(), term()) :: term()
  def call(name, msg), do: :gen_statem.call(name, msg)

  @doc "Asynchronously deliver a typed event to the twin."
  @spec send_event(atom(), term()) :: :ok
  def send_event(name, event), do: :gen_statem.cast(name, event)

  @doc "Stop the twin."
  @spec stop(atom()) :: :ok
  def stop(name), do: :gen_statem.stop(name)

  # -- gen_statem callbacks -------------------------------------------------

  @impl true
  def init({name, kind, opts}) do
    data = %{
      name: name,
      kind: kind,
      listener: Keyword.get(opts, :listener, self()),
      clock: Keyword.get(opts, :clock, {:mono, fn -> :erlang.monotonic_time(:native) end}),
      kind_state: init_kind(kind, opts)
    }

    {:ok, :ready, data}
  end

  defp init_kind(:asset, opts) do
    %{
      sla_ms: Keyword.get(opts, :sla_ms, 5_000),
      window_start: nil,
      armed?: false,
      ops_count: 0
    }
  end

  defp init_kind(:partner, opts) do
    capacity = Keyword.get(opts, :window_capacity, AshA2A.Twin.Hazard.default_capacity())

    %{
      shift: :off_shift,
      hazard: Hazard.new(capacity),
      threshold: Keyword.get(opts, :threshold, AshA2A.Twin.Hazard.default_threshold()),
      pending_dispatch: nil,
      acked?: true
    }
  end

  defp init_kind(:operator, opts) do
    %{
      budget: Keyword.get(opts, :budget, 10),
      queue: :queue.new(),
      depth: 0
    }
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def handle_event({:call, from}, :status, _state, data),
    do: {:keep_state, data, [{:reply, from, status_map(data)}]}

  # -- Asset ----------------------------------------------------------------

  def handle_event(:cast, {:activity, ref}, _s, %{kind: :asset} = data) do
    %{kind_state: ks} = data
    now = clock_ms(data.clock)

    ks2 = %{ks | window_start: now, armed?: true, ops_count: ks.ops_count + 1}

    {:keep_state, %{data | kind_state: ks2},
     [{{:timeout, :sla}, ks.sla_ms, {:sla_check, ref, now}}]}
  end

  def handle_event({:timeout, :sla}, {:sla_check, ref, started}, _s, %{kind: :asset} = data) do
    %{kind_state: ks} = data

    if ks.armed? and ks.window_start == started do
      send(data.listener, {:sla_expired, data.name, %{ref: ref, sla_ms: ks.sla_ms}})
      {:keep_state, %{data | kind_state: %{ks | armed?: false}}}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:cast, :disarm, _s, %{kind: :asset} = data) do
    ks = data.kind_state
    {:keep_state, %{data | kind_state: %{ks | armed?: false}}, [{{:timeout, :sla}, :cancel}]}
  end

  # -- Partner ---------------------------------------------------------------

  def handle_event(:cast, :shift_on, _s, %{kind: :partner} = data),
    do: set_shift(data, :on_shift)

  def handle_event(:cast, :shift_off, _s, %{kind: :partner} = data),
    do: set_shift(data, :off_shift)

  def handle_event(:cast, {:dispatch, ref}, _s, %{kind: :partner} = data) do
    ks = data.kind_state

    if ks.shift == :on_shift do
      {:keep_state, %{data | kind_state: %{ks | pending_dispatch: ref, acked?: false}}}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:cast, {:response, latency}, _s, %{kind: :partner} = data)
      when is_number(latency) do
    ks = data.kind_state

    case Hazard.observe(ks.hazard, latency) do
      {:ok, stats} ->
        conclude_response(%{data | kind_state: %{ks | hazard: stats.monitor}}, stats)

      {:error, :insufficient_dispersion} ->
        # zero-dispersion window: push the observation so the window heals;
        # no trip is possible on an empty/zero-dispersion window.
        {:keep_state, %{data | kind_state: %{ks | hazard: Hazard.push(ks.hazard, latency)}}}
    end
  end

  def handle_event(:cast, :ack, _s, %{kind: :partner} = data) do
    ks = data.kind_state
    {:keep_state, %{data | kind_state: %{ks | acked?: true, pending_dispatch: nil}}}
  end

  def handle_event(:cast, _other, _s, %{kind: :partner}), do: :keep_state_and_data

  # -- Operator --------------------------------------------------------------

  def handle_event(:cast, {:enqueue, item}, _s, %{kind: :operator} = data) do
    ks = data.kind_state
    queue = :queue.in(item, ks.queue)
    {:keep_state, %{data | kind_state: %{ks | queue: queue, depth: ks.depth + 1}}}
  end

  def handle_event(:cast, :attend, _s, %{kind: :operator} = data) do
    ks = data.kind_state

    case :queue.out(ks.queue) do
      {{:value, _item}, rest} when ks.budget > 0 ->
        budget = ks.budget - 1
        ks2 = %{ks | queue: rest, depth: ks.depth - 1, budget: budget}

        if budget == 0 do
          send(data.listener, {:budget_exhausted, data.name, %{depth: ks2.depth}})
        end

        {:keep_state, %{data | kind_state: ks2}}

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:cast, :recharge, _s, %{kind: :operator} = data) do
    ks = data.kind_state
    {:keep_state, %{data | kind_state: %{ks | budget: ks.budget + 5}}}
  end

  def handle_event({:call, from}, {:peek, n}, _s, %{kind: :operator} = data) do
    ks = data.kind_state
    items = ks.queue |> :queue.to_list() |> Enum.take(n)
    {:keep_state, data, [{:reply, from, items}]}
  end

  # -- fallback --------------------------------------------------------------

  def handle_event(_type, _content, _state, _data), do: :keep_state_and_data

  # -- internals -------------------------------------------------------------

  defp set_shift(data, shift) do
    ks = data.kind_state

    if ks.shift != shift do
      send(data.listener, {:shift_changed, data.name, shift})
    end

    {:keep_state, %{data | kind_state: %{ks | shift: shift}}}
  end

  defp conclude_response(data, stats) do
    ks = data.kind_state

    trips? =
      # hours-before-SLA semantics: threshold configurable in sigma or absolute
      # seconds; trip only for an unacknowledged outstanding dispatch on shift.
      Hazard.trip?(stats.z, ks.threshold) and not ks.acked? and
        not is_nil(ks.pending_dispatch) and ks.shift == :on_shift

    ks2 =
      if trips? do
        send(
          data.listener,
          {:hazard_tripped, data.name, stats.z,
           stats |> Map.put(:dispatch, ks.pending_dispatch) |> Map.delete(:monitor)}
        )

        %{ks | pending_dispatch: nil}
      else
        ks
      end

    {:keep_state, %{data | kind_state: ks2}}
  end

  defp clock_ms({:mono, fun}) when is_function(fun, 0), do: fun.()
  defp clock_ms(_), do: System.system_time(:millisecond)

  defp status_map(%{kind: :asset, kind_state: ks} = d),
    do: %{
      name: d.name,
      kind: :asset,
      sla_ms: ks.sla_ms,
      ops_count: ks.ops_count,
      armed?: ks.armed?
    }

  defp status_map(%{kind: :partner, kind_state: ks} = d),
    do: %{
      name: d.name,
      kind: :partner,
      shift: ks.shift,
      acked?: ks.acked?,
      threshold: ks.threshold,
      window_size: length(Hazard.window(ks.hazard))
    }

  defp status_map(%{kind: :operator, kind_state: ks} = d),
    do: %{name: d.name, kind: :operator, depth: ks.depth, budget: ks.budget}
end
