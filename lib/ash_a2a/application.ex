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

  The same automatic-wiring treatment now also covers `:authority_broker`
  (v26.9.17): choosing `AshA2A.Authority.Broker.Ekv` starts a second,
  distinctly-named-and-pathed `EKV` instance on the broker's behalf, the same
  way choosing `AshA2A.ReceiptStore.Ekv` already does for the receipt store.
  Before this, `docs/how-to/authenticate-agent-requests.md`'s own primary
  example (`config :ash_a2a, :authority_broker, AshA2A.Authority.Broker.Ekv`)
  was not actually config-only: `AshA2A.Authority.Broker.Ekv`'s moduledoc is
  explicit that it "does not start or supervise `EKV` itself," so a host that
  followed the doc verbatim, with no separate supervision-tree change of
  their own, got `:broker_unavailable`/`false` on every real `granted?/3`
  call the moment traffic arrived -- a real gap between what the config
  claimed to do and what the running system did, closed here.
  `AshA2A.Authority.Broker.InMemory` keeps its existing host-started
  convention (this project's own test suite starts it explicitly in
  `test/test_helper.exs`, matching `AshA2A.Authority.Broker`'s own
  moduledoc); only the durable `Ekv` broker gets automatic wiring, matching
  the receipt-store precedent exactly (`AshA2A.ReceiptStore.Memory` also
  keeps its non-`Ekv` clause auto-started below -- that asymmetry with the
  broker's `InMemory` is deliberate: this application already owned starting
  `ReceiptStore.Memory` before this change, so extending that same clause to
  the broker's `InMemory` would double-start the one GenServer the existing
  test suite starts itself, for a broker whose whole model is exactly this
  "host starts it in their own supervision tree" convention -- see
  `AshA2A.Authority.Broker`'s moduledoc, unlike the receipt store, which
  never asked hosts to hand-start `Memory`).
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

    # Seeds this runtime's standing-ledger key before any envelope can be
    # sealed, so two concurrent first-transitions cannot race on generating it.
    # `AshA2A.Semantic.Standing` seals every standing transition under this key
    # and re-verifies the seal on the next one -- that chain is what makes
    # `%AshA2A.Semantic.Envelope{standing: :admitted}` a refusal rather than a
    # standing. See that module's "Standing cannot be forged" section.
    :ok = AshA2A.Semantic.Standing.ensure_ledger_key()

    children =
      receipt_store_children() ++
        authority_broker_children() ++
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
          # RFC-SA2A-001 S12/S79: the real `praxis-graphlaw` WebAssembly
          # law package, hosted by `AshA2A.GraphLaw.WasmexHost`. A Wasmtime
          # instance over a 3.2 MB module is not free to create, so it is
          # created once here and reused; that GenServer also serializes
          # the multi-step wasm-bindgen ABI transactions, which is what
          # makes the single shared instance safe for concurrent BEAM
          # callers (see its moduledoc). Starting it is safe with the
          # artifact absent -- `init/1` degrades to a typed-error state and
          # logs a warning rather than crashing the supervision tree, the
          # same "missing native artifact is a typed error, not a crash"
          # convention `AshA2A.Planning.HddlSolver` already follows. It
          # carries NO authority: GraphLaw derives and validates, it never
          # authorizes and never actuates (RFC S4.4/S17), so starting it
          # changes no existing admission or dispatch behavior.
          {AshA2A.GraphLaw.WasmexHost, []},
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

  # Mirrors `receipt_store_children/0` for the authority-broker layer.
  # `:authority_broker` may be a bare module or a `{module, broker_opts}`
  # tuple (see `AshA2A.Authority.Grant.resolve_broker/1`); both forms are
  # normalized here the same way `resolve_broker/1` does, so a host that
  # names a custom `:name` in `broker_opts` gets that exact `EKV` instance
  # started rather than this function silently falling back to the default.
  defp authority_broker_children do
    case Application.get_env(:ash_a2a, :authority_broker) do
      AshA2A.Authority.Broker.Ekv ->
        [{EKV, authority_broker_ekv_opts([])}]

      {AshA2A.Authority.Broker.Ekv, broker_opts} when is_list(broker_opts) ->
        [{EKV, authority_broker_ekv_opts(broker_opts)}]

      _other ->
        # `nil` (unconfigured), `AshA2A.Authority.Broker.InMemory` (host- or
        # test-started, see the moduledoc above), and any custom broker all
        # own their own supervision lifecycle -- exactly
        # `receipt_store_children/0`'s own `_custom_store -> []` precedent.
        []
    end
  end

  # Deliberately a DIFFERENT default `:name` and `:data_dir` than
  # `receipt_store_ekv_opts/0`: `AshA2A.Authority.Broker.Ekv`'s own moduledoc
  # states distinct `EKV` instances are how more than one independently
  # configured broker/store avoids colliding on unrelated key spaces (grant
  # revocation state vs. receipt/claim state) -- reusing the receipt store's
  # instance here would put authority grants and command receipts in the same
  # on-disk keyspace for no reason other than accident.
  defp authority_broker_ekv_opts(broker_opts) do
    default_data_dir = Path.join(System.tmp_dir!(), "ash_a2a_authority_broker_ekv")

    broker_opts
    |> Keyword.put_new(:name, AshA2A.Authority.Broker.Ekv)
    |> Keyword.put_new(:data_dir, default_data_dir)
    |> Keyword.put_new(:cluster_size, 1)
  end
end
