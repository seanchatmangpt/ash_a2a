defmodule AshA2A.Application do
  @moduledoc """
  Starts the A2A agent supervisor, the default replay receipt store, and the
  default semantic `AshA2A.Semantic.PackageStore` (GAP B: receipt -> feedback
  -> replan closure needs a real, addressable place to resolve a caller's
  `:continuation_fingerprint` back to the full `AshA2A.Semantic.
  ExecutionPackage` it names -- see that module's `@moduledoc` for why this is
  a separate store from `:receipt_store`, not a field on it).

  Host applications may replace `:receipt_store` with another
  `AshA2A.ReceiptStore` implementation; non-default stores own their own
  supervision lifecycle. `AshA2A.Semantic.PackageStore` is always started
  under its own default registered name -- it has no swappable-behaviour
  config today (no host has needed a second implementation yet).
  """

  use Application

  @impl true
  def start(_type, _args) do
    agents = Application.get_env(:ash_a2a, :agents, [])

    # `AshA2A.Telemetry.OcelForwarder.attach!/0` is real and correct
    # (`ocel_forwarder.ex`) but was never called from anywhere in `lib/` --
    # only 3 test files attached it directly, so a host app got no OCEL
    # forwarding for `[:ash_a2a, :dispatch, :stop]`/`[:ash_a2a, :receipt,
    # :committed]` events by default, silently. Attaching here is a real
    # no-op cost when unconfigured: `attach/2` is idempotent
    # (`{:error, :already_exists} -> :ok`) and `handle_event/4` only ever
    # POSTs when `Application.get_env(:ash_a2a, :ocel_ingest_url)` is set --
    # otherwise every event handler short-circuits to `:ok`. This makes the
    # forwarder live-by-default the moment a host configures an ingest URL,
    # instead of requiring every host to remember to call `attach!/0` itself.
    :ok = AshA2A.Telemetry.OcelForwarder.attach!()

    children =
      receipt_store_children() ++
        [
          # A2A-2602: the OCEL forwarder's per-event supervised tasks are
          # BOUNDED. `max_children` is the hard concurrency ceiling for the
          # observational egress; beyond it `Task.Supervisor.start_child/2`
          # returns `{:error, :max_children}`, which the forwarder accounts
          # as an explicit shed (counter + telemetry), never as an unbounded
          # process fan-out. Default 256 concurrent in-flight HTTP POSTs;
          # tune per host via `config :ash_a2a, :ocel_max_in_flight, n`.
          {Task.Supervisor,
           name: AshA2A.Telemetry.TaskSupervisor,
           max_children: Application.get_env(:ash_a2a, :ocel_max_in_flight, 256)},
          {AshA2A.Semantic.PackageStore, []},
          # `AshA2A.KillSwitch`: a real, standalone class-level halt
          # primitive (see its moduledoc). Started here as a node-wide
          # singleton, the same idiom as `AshA2A.Semantic.PackageStore`
          # above -- NOT consulted by `AshA2A.CommandBus.admit/2` or any
          # other dispatch path today, so starting it changes no existing
          # admission/fencing behavior; it is simply available for a host
          # (or a future, separately-scoped change) to call.
          {AshA2A.KillSwitch, []},
          {A2A.AgentSupervisor, agents: agents}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshA2A.Supervisor)
  end

  defp receipt_store_children do
    case Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory) do
      AshA2A.ReceiptStore.Memory ->
        [{AshA2A.ReceiptStore.Memory, []}]

      AshA2A.ReceiptStore.Ekv ->
        # `AshA2A.ReceiptStore.Ekv` needs a real, already-started `EKV`
        # instance under its configured `:name` -- unlike
        # `AshA2A.ReceiptStore.Memory`, which owns its own GenServer, `EKV`
        # is a separate supervised child this application starts on the
        # store's behalf so choosing `AshA2A.ReceiptStore.Ekv` gets the same
        # automatic wiring the default store gets, rather than requiring
        # every host to hand-start `EKV` itself.
        [{EKV, receipt_store_ekv_opts()}]

      _custom_store ->
        []
    end
  end

  # `:name`, `:data_dir`, and `:cluster_size` are given sensible defaults so
  # `receipt_store: AshA2A.ReceiptStore.Ekv` works with zero extra config;
  # a host overrides any of them via `config :ash_a2a,
  # receipt_store_ekv_opts: [...]` (for example a real persistent
  # `:data_dir` outside the OS tmp directory for production durability --
  # the tmp-dir default below is fine for local/dev use, where surviving a
  # single BEAM restart is the point, but is not guaranteed to survive a
  # host reboot on every platform).
  defp receipt_store_ekv_opts do
    default_data_dir = Path.join(System.tmp_dir!(), "ash_a2a_receipt_store_ekv")

    :ash_a2a
    |> Application.get_env(:receipt_store_ekv_opts, [])
    |> Keyword.put_new(:name, AshA2A.ReceiptStore.Ekv)
    |> Keyword.put_new(:data_dir, default_data_dir)
    |> Keyword.put_new(:cluster_size, 1)
  end
end
