defmodule AshA2A.Providers.PPlanNotifyTest do
  @moduledoc """
  Lane P2 court for `AshA2A.Providers.PPlanNotify`, over the REAL stack: a
  disk-backed `AshPPlan.Reactor.Durable.Store.Dets` on a tmp dir, a real
  `AshA2A.A2ATransport` (TaskEvents + PushConfigStore + push supervisor), the
  real `PushDelivery.deliver/5` path, and a real Bandit receiver. Zero mocks.

  ## Court legs

    1. **Bridge**: parked run + registered push config -> `resume/3` ->
       completion -> the real receiver gets the signed wrapped v1.0 body
       (`{"task" => {"id", "status": {"state": "TASK_STATE_COMPLETED"}}}`, no
       `"final"`), exactly once.
    2. **Receiver-down**: the attempt records the typed
       `{:error, {:transport_error, _}}` outcome, retries on later ticks, and
       stops when the task is unwatched.
    3. **Restart dedup**: killing and re-opening the store produces NO
       duplicate delivery — the `notified` dedup set is keyed
       `{task_id, config_id, record.version}` and held in the notifier, so a
       store restart cannot duplicate a notified transition.

  ## Durability-court skip discipline

  If `:ash_pplan` cannot load in the test env, every test skips with a typed
  BLOCKED reason (`{:blocked, :ash_pplan_not_loadable}`) printed to stderr —
  a named finding, never a silent pass.
  """

  use ExUnit.Case, async: false

  @dets AshPPlan.Reactor.Durable.Store.Dets
  @secret "p2-notify-signing-secret"

  # -- real collaborators -------------------------------------------------------

  defmodule Receiver do
    @moduledoc false
    # Real webhook receiver: forwards (method, headers, body) to the test pid
    # and answers 200. Body shape and HMAC are re-asserted in the test process.
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:webhook, conn.method, conn.req_headers, body})
      send_resp(conn, 200, "")
    end
  end

  defmodule Effects do
    @moduledoc "Real counting agent: each consequential effect records exactly here."
    use Agent

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def run(server, effect) do
      Agent.get_and_update(server, fn s ->
        n = Map.get(s, effect, 0) + 1
        {{:ok, n}, Map.put(s, effect, n)}
      end)
    end

    def count(server, effect), do: Agent.get(server, &Map.get(&1, effect, 0))
  end

  defmodule Effect do
    @moduledoc "Counting Reactor step; `options[:effect]` names the counter."
    use Reactor.Step

    def run(_arguments, _context, options) do
      case Effects.run(Keyword.fetch!(options, :effects), Keyword.fetch!(options, :effect)) do
        {:ok, n} -> {:ok, {Keyword.fetch!(options, :effect), n}}
        {:error, _} = err -> err
      end
    end
  end

  defmodule Adapter do
    @moduledoc """
    Test adapter: counting effects plus ash_pplan's own Await durable step.
    Realization options carry the per-test `:effects` agent name (data,
    survives a store round trip).
    """

    @behaviour AshPPlan.Reactor.Adapter

    @impl true
    def id, do: :a2a_p2_notify_fx

    @impl true
    def available?, do: true

    @impl true
    def ops, do: [:process_prepare, :process_finish, :event_await]

    @impl true
    def step(op, options) do
      table = %{
        process_prepare: {Effect, [effect: :prepare]},
        process_finish: {Effect, [effect: :finish]},
        event_await: {AshPPlan.Reactor.Durable.Steps.Await, [signal: "go", timeout: nil]}
      }

      AshPPlan.Reactor.Adapter.resolve(__MODULE__, table, op, options)
    end
  end

  # -- fixtures -----------------------------------------------------------------

  alias AshA2A.A2ATransport.{PushConfigStore, PushDelivery, TaskEvents}

  setup do
    unless AshA2A.Providers.PPlanNotify.available?() do
      reason = {:blocked, :ash_pplan_not_loadable}

      IO.puts(:stderr, "[lane-p2] BLOCKED: :ash_pplan did not load in the test env")

      {:skip, reason}
    end

    install_adapter!()
    uniq = System.unique_integer([:positive])

    {:ok, fx} = Effects.start_link(:"p2_notify_fx_#{uniq}")
    dets_name = :"p2_dets_#{uniq}"
    {store, path} = open_store(dets_name)

    transport = :"a2a_transport_p2_notify_#{uniq}"

    push_opts = [
      allow_http: true,
      allow_cidrs: ["127.0.0.1/32"],
      signing_secret: @secret,
      max_attempts: 2,
      base_backoff_ms: 10
    ]

    start_supervised!({AshA2A.A2ATransport, name: transport, push: push_opts})

    hook = AshA2A.Test.EphemeralHttp.start!({Receiver, %{test: self()}}).base_url <> "/hook"

    notify =
      start_supervised!(
        {AshA2A.Providers.PPlanNotify,
         name: :"p2_notify_#{uniq}",
         store: dets_name,
         store_module: @dets,
         push_store: AshA2A.A2ATransport.push_store_name(transport),
         transport: transport,
         push_opts: push_opts,
         interval: 20}
      )

    %{
      fx: fx,
      store: store,
      dets_name: dets_name,
      path: path,
      transport: transport,
      push_store: AshA2A.A2ATransport.push_store_name(transport),
      notify: notify,
      hook: hook,
      opts: [store: dets_name, store_module: @dets]
    }
  end

  defp install_adapter! do
    previous = Application.get_env(:ash_pplan, :extra_adapters, %{})

    Application.put_env(
      :ash_pplan,
      :extra_adapters,
      Map.put(Map.new(previous), :a2a_p2_notify_fx, Adapter)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_pplan, :extra_adapters, previous)
    end)

    :ok
  end

  defp open_store(name) do
    path =
      Path.join(System.tmp_dir!(), "a2a-pplan-laneP2-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    {:ok, store} = @dets.start_link(path: path, name: name)
    # the restart court kills the store; a live link would take the test down
    Process.unlink(store)
    {store, path}
  end

  defp model(name, tasks) do
    {:ok, m} = AshPPlan.Workflow.Model.new(name: name, goal: name, tasks: tasks)
    m
  end

  defp await_model,
    do:
      model("p2_notify_await", [
        [id: :prepare, capability: "Process.Prepare", depends_on: []],
        [id: :await, capability: "Event.Await", depends_on: [:prepare]],
        [id: :finish, capability: "Process.Finish", depends_on: [:await]]
      ])

  defp bindings(fx) do
    ops = [
      {:prepare, "Process.Prepare"},
      {:finish, "Process.Finish"},
      {:await, "Event.Await"}
    ]

    Map.new(ops, bindings_entry(fx))
  end

  defp bindings_entry(fx) do
    fn {task, cap} ->
      {task,
       %AshPPlan.Realization{
         capability: cap,
         provider: :a2a_p2_notify_fx,
         binding: %{adapter: :a2a_p2_notify_fx, op: AshPPlan.Realization.op_for(cap)},
         options: [effects: fx]
       }}
    end
  end

  # Park a run on its Await step, register a push config for the task, and
  # start watching. Returns the task id.
  defp park_and_watch(ctx, task_id, url, config_id) do
    assert {:ok, :input_required, ["go"]} =
             AshA2A.Providers.PPlan.dispatch(task_id, await_model(), bindings(ctx.fx), ctx.opts)

    assert {:ok, _record} =
             PushConfigStore.put(ctx.push_store, %{
               id: config_id,
               task_id: task_id,
               url: url,
               token: "tok-" <> config_id
             })

    assert :ok = AshA2A.Providers.PPlanNotify.watch(ctx.notify, task_id)

    task_id
  end

  # Wait (bounded) until the notify server's delivery log satisfies `pred`.
  defp wait_delivery(notify, pred, tries \\ 150)

  defp wait_delivery(_notify, _pred, 0), do: flunk("expected a matching delivery, got none")

  defp wait_delivery(notify, pred, tries) do
    case Enum.find(AshA2A.Providers.PPlanNotify.deliveries(notify), pred) do
      nil ->
        Process.sleep(20)
        wait_delivery(notify, pred, tries - 1)

      entry ->
        entry
    end
  end

  defp delivery_count(notify), do: length(AshA2A.Providers.PPlanNotify.deliveries(notify))

  # -- (1) the bridge ------------------------------------------------------------

  test "resumed parked run completes and the real receiver gets the signed wrapped body exactly once",
       %{
         fx: fx,
         dets_name: dets_name,
         transport: transport,
         push_store: push_store,
         notify: notify,
         hook: hook
       } do
    opts = [store: dets_name, store_module: @dets]

    task_id =
      park_and_watch(%{fx: fx, push_store: push_store, notify: notify, opts: opts},
        "a2a-p2-notify-ok-1",
        hook,
        "cfg-ok"
      )

    assert {:ok, :completed, _result} = AshA2A.Providers.PPlan.resume(task_id, %{n: 1}, opts)

    assert_receive {:webhook, "POST", headers, body}, 5_000
    headers = Map.new(headers)

    assert headers["x-a2a-notification-token"] == "tok-cfg-ok"
    assert headers["content-type"] == "application/json"

    # Receiver-side HMAC verification against the real signing secret.
    assert :ok =
             PushDelivery.verify_signature(
               @secret,
               headers["x-a2a-timestamp"],
               headers["x-a2a-signature"],
               body
             )

    # The SAME wrapped v1.0 shape the in-process path delivers: `{"task" =>
    # ...}` with the terminal wire state and no "final" boolean anywhere.
    decoded = Jason.decode!(body)

    assert %{
             "task" => %{
               "id" => ^task_id,
               "status" => %{"state" => "TASK_STATE_COMPLETED"}
             }
           } = decoded

    refute Map.has_key?(decoded, "final")
    refute body =~ ~s("final")

    # Exactly one delivery was recorded, and it succeeded.
    entry = wait_delivery(notify, &(&1.task_id == task_id and &1.outcome == :ok))
    assert entry.config_id == "cfg-ok"

    # The delivery rode the REAL PushDelivery path: the attempt is recorded in
    # the transport's TaskEvents with the real 200.
    assert [%{attempt: 1, outcome: {:ok, 200}, config_id: "cfg-ok"}] =
             TaskEvents.attempts(transport, task_id)

    # Exactly-once: the ticks keep coming, no second webhook, no second delivery.
    Process.sleep(120)
    refute_received {:webhook, "POST", _h, _b}
    assert delivery_count(notify) == 1
  end

  # -- (2) receiver down: typed failure -------------------------------------------

  test "receiver-down attempt records the typed transport failure and stops after unwatch",
       %{fx: fx, dets_name: dets_name, push_store: push_store, notify: notify} do
    opts = [store: dets_name, store_module: @dets]

    task_id =
      park_and_watch(
        %{fx: fx, push_store: push_store, notify: notify, opts: opts},
        "a2a-p2-notify-down-1",
        "http://127.0.0.1:9/hook",
        "cfg-down"
      )

    assert {:ok, :completed, _} = AshA2A.Providers.PPlan.resume(task_id, %{n: 2}, opts)

    entry = wait_delivery(notify, &(&1.task_id == task_id and match?({:error, _}, &1.outcome)))

    assert {:error, {:transport_error, detail}} = entry.outcome
    assert is_binary(detail) and detail != ""

    # nothing reached the real receiver from this task
    refute_received {:webhook, "POST", _h, _b}

    # failures are retried on later ticks until success (at-least-once toward
    # the receiver), and unwatch stops them.
    count_before = delivery_count(notify)
    assert :ok = AshA2A.Providers.PPlanNotify.unwatch(notify, task_id)
    Process.sleep(120)
    assert delivery_count(notify) == count_before
  end

  # -- (3) store restart: no duplicate delivery (dedup scope pinned) ---------------

  test "store restart produces no duplicate delivery (dedup scope {task, config, version} holds)",
       %{
         fx: fx,
         store: store,
         dets_name: dets_name,
         path: path,
         push_store: push_store,
         notify: notify,
         hook: hook
       } do
    opts = [store: dets_name, store_module: @dets]

    task_id =
      park_and_watch(
        %{fx: fx, push_store: push_store, notify: notify, opts: opts},
        "a2a-p2-notify-restart-1",
        hook,
        "cfg-restart"
      )

    assert {:ok, :completed, _} = AshA2A.Providers.PPlan.resume(task_id, %{n: 3}, opts)

    assert_receive {:webhook, "POST", _headers, _body}, 5_000
    wait_delivery(notify, &(&1.task_id == task_id and &1.outcome == :ok))
    assert delivery_count(notify) == 1

    # Kill the store hard and re-open the SAME DETS file at the SAME name: the
    # poll loop re-binds and keeps polling the revived record.
    Process.exit(store, :kill)
    refute Process.alive?(store)

    {:ok, _store2} = @dets.start_link(path: path, name: dets_name)

    Process.sleep(150)
    refute_received {:webhook, "POST", _h, _b}
    assert delivery_count(notify) == 1
  end
end
