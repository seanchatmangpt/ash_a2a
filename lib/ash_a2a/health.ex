defmodule AshA2A.Health do
  @moduledoc """
  Liveness and readiness for an `:ash_a2a` node, aggregated from real
  component state so an orchestrator can gate traffic (OBS-06/OBS-07).

    * `liveness/0` -- the `AshA2A.Supervisor` tree is running.
    * `readiness/0` -- `{status, %{checks: ..., runtime: ...}}` with
      `status in [:ok, :degraded, :down]`. Every check reports its own
      `:status` and facts; the aggregate is the worst check.
    * `runtime_facts/0` -- the effective receipt-store / authority-broker
      configuration (module, durability, whether a data dir is under the OS
      tmp directory). `AshA2A.Application` emits the same facts at boot as
      `[:ash_a2a, :runtime, :configured]`.

  ## Checks

  | check | `:down` when | `:degraded` when |
  |---|---|---|
  | `:supervisor` | `AshA2A.Supervisor` not running | -- |
  | `:receipt_store` | a store child that should be running is not | store is not durable, or its data dir is under tmp |
  | `:receipt_outbox` | -- | pending entries > `:outbox_ready_max` (default 1000), or the outbox reconciler is not running |
  | `:graph_law` | -- | the GraphLaw WASM engine is not loaded |
  | `:kill_switch` | a class in `:health_kill_switch_classes` is tripped, or the kill switch is not running | -- |
  | `:ocel` | -- | `failed_count/0` exceeds `:health_ocel_failed_max` (unset = informational) |

  `readiness/0` emits `[:ash_a2a, :health, :checked]` with
  `%{duration: native}` and `%{status: status}`.

  This module is observational: it reads state and never changes admission,
  dispatch, or receipt behaviour. `AshA2A.Health.Plug` serves it over HTTP.
  """

  alias AshA2A.Telemetry.OcelForwarder

  @type status :: :ok | :degraded | :down
  @type check :: %{required(:status) => status(), optional(atom()) => term()}

  @default_outbox_ready_max 1_000

  @doc "Whether the `:ash_a2a` supervision tree is running."
  @spec liveness() :: {:ok | :down, map()}
  def liveness do
    case supervisor_check() do
      %{status: :ok} = check -> {:ok, %{checks: %{supervisor: check}}}
      check -> {:down, %{checks: %{supervisor: check}}}
    end
  end

  @doc "Aggregated readiness over every component check."
  @spec readiness() :: {status(), map()}
  def readiness do
    started = System.monotonic_time()

    checks = %{
      supervisor: guarded(&supervisor_check/0),
      receipt_store: guarded(&receipt_store_check/0),
      receipt_outbox: guarded(&receipt_outbox_check/0),
      graph_law: guarded(&graph_law_check/0),
      kill_switch: guarded(&kill_switch_check/0),
      ocel: guarded(&ocel_check/0)
    }

    status = aggregate(checks)

    :telemetry.execute(
      [:ash_a2a, :health, :checked],
      %{duration: System.monotonic_time() - started},
      %{status: status}
    )

    {status, %{checks: checks}}
  end

  @doc false
  @spec aggregate(%{atom() => check()}) :: status()
  def aggregate(checks) do
    statuses = checks |> Map.values() |> Enum.map(& &1.status)

    cond do
      :down in statuses -> :down
      :degraded in statuses -> :degraded
      true -> :ok
    end
  end

  @doc """
  The effective runtime configuration facts for receipts and authority.

  `durable` is `true` only when the configured store module exports
  `durable?/0` returning `true` AND (for the EKV-backed store) its data dir
  is outside the OS tmp directory.
  """
  @spec runtime_facts() :: map()
  def runtime_facts do
    store = Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory)
    data_dir = store_data_dir(store)
    data_dir_tmp = tmp_path?(data_dir)
    outbox_dir = AshA2A.ReceiptOutbox.dir()

    %{
      receipt_store: store,
      store_declares_durable: store_declares_durable?(store),
      durable: store_declares_durable?(store) and not data_dir_tmp,
      data_dir: data_dir,
      data_dir_tmp: data_dir_tmp,
      receipt_outbox_dir: outbox_dir,
      receipt_outbox_dir_tmp: tmp_path?(outbox_dir),
      authority_broker: broker_module(Application.get_env(:ash_a2a, :authority_broker))
    }
  end

  defp store_data_dir(AshA2A.ReceiptStore.Ekv) do
    :ash_a2a
    |> Application.get_env(:receipt_store_ekv_opts, [])
    |> Keyword.get(
      :data_dir,
      Path.join(System.tmp_dir!(), "ash_a2a_receipt_store_ekv")
    )
  end

  defp store_data_dir(_store), do: nil

  defp store_declares_durable?(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :durable?, 0) and
      store.durable?() == true
  rescue
    _ -> false
  end

  @doc false
  @spec tmp_path?(String.t() | nil) :: boolean()
  def tmp_path?(nil), do: false

  def tmp_path?(path) when is_binary(path) do
    tmp = System.tmp_dir!() |> Path.expand() |> String.trim_trailing("/")
    expanded = Path.expand(path)
    expanded == tmp or String.starts_with?(expanded, tmp <> "/")
  end

  defp broker_module({module, _opts}) when is_atom(module), do: module
  defp broker_module(module), do: module

  # -- checks -----------------------------------------------------------

  defp supervisor_check do
    case Process.whereis(AshA2A.Supervisor) do
      pid when is_pid(pid) -> %{status: :ok}
      nil -> %{status: :down, reason: :supervisor_not_running}
    end
  end

  defp receipt_store_check do
    facts = runtime_facts()
    running? = store_running?(facts.receipt_store)

    status =
      cond do
        not running? -> :down
        not facts.durable -> :degraded
        true -> :ok
      end

    %{
      status: status,
      store: facts.receipt_store,
      running: running?,
      durable: facts.durable,
      data_dir_tmp: facts.data_dir_tmp
    }
  end

  defp store_running?(AshA2A.ReceiptStore.Memory),
    do: is_pid(Process.whereis(AshA2A.ReceiptStore.Memory))

  defp store_running?(AshA2A.ReceiptStore.Ekv) do
    name =
      :ash_a2a
      |> Application.get_env(:receipt_store_ekv_opts, [])
      |> Keyword.get(:name, AshA2A.ReceiptStore.Ekv)

    # `EKV.Supervisor.start_link/1` registers as `:"\#{name}_ekv_sup"`.
    is_atom(name) and is_pid(Process.whereis(:"#{name}_ekv_sup"))
  end

  # Custom stores own their own lifecycle; nothing here can observe them.
  defp store_running?(_custom), do: true

  defp receipt_outbox_check do
    max = Application.get_env(:ash_a2a, :outbox_ready_max, @default_outbox_ready_max)
    depth = safe(fn -> AshA2A.ReceiptOutbox.count() end, :unreadable)
    reconciler? = is_pid(Process.whereis(AshA2A.ReceiptOutbox.Reconciler))

    status =
      cond do
        depth == :unreadable -> :degraded
        depth > max -> :degraded
        not reconciler? -> :degraded
        true -> :ok
      end

    %{status: status, depth: depth, max: max, reconciler_running: reconciler?}
  end

  defp graph_law_check do
    if AshA2A.GraphLaw.WasmexHost.available?(AshA2A.GraphLaw.WasmexHost, 1_000),
      do: %{status: :ok, engine: :loaded},
      else: %{status: :degraded, engine: :unavailable}
  end

  defp kill_switch_check do
    if is_pid(Process.whereis(AshA2A.KillSwitch)) do
      tripped =
        :ash_a2a
        |> Application.get_env(:health_kill_switch_classes, [])
        |> Enum.filter(fn class -> AshA2A.KillSwitch.tripped?(class) != false end)

      if tripped == [],
        do: %{status: :ok, tripped: []},
        else: %{status: :down, tripped: tripped}
    else
      %{status: :down, reason: :kill_switch_not_running}
    end
  end

  defp ocel_check do
    failed = OcelForwarder.failed_count()
    max = Application.get_env(:ash_a2a, :health_ocel_failed_max)

    status = if is_integer(max) and failed > max, do: :degraded, else: :ok

    %{
      status: status,
      configured: not is_nil(Application.get_env(:ash_a2a, :ocel_ingest_url)),
      delivered: OcelForwarder.delivered_count(),
      failed: failed,
      shed: OcelForwarder.shed_count()
    }
  end

  # readiness/0 is total: a check that raises or exits (a misconfigured
  # `:health_kill_switch_classes` entry, a component mid-restart) reports
  # itself `:down` with the failure KIND only, instead of crashing the probe
  # (which would surface as an HTTP 500 and skip `[:ash_a2a, :health,
  # :checked]`). Fail closed: an unobservable component is not ready.
  defp guarded(check_fun) do
    check_fun.()
  rescue
    error -> %{status: :down, reason: :check_failed, error: error.__struct__}
  catch
    kind, _reason -> %{status: :down, reason: :check_failed, error: kind}
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
