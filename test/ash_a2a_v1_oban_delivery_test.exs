defmodule AshA2A.V1.ObanDeliveryTest.Receiver do
  @moduledoc false
  # Real Bandit webhook receiver mirroring W6's
  # (test/ash_a2a_v1_push_httpjson_test.exs): forwards (method, headers, body)
  # to the test pid and answers 200. The body shape is re-asserted in the test
  # process.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{test: test}) do
    {:ok, body, conn} = read_body(conn)
    send(test, {:webhook, conn.method, conn.req_headers, body})
    send_resp(conn, 200, "")
  end
end

defmodule AshA2A.V1.ObanDeliveryTest.Probe do
  @moduledoc false
  # Real ETS-backed Ash resource with one real `:read` skill.
  use Ash.Resource,
    domain: AshA2A.V1.ObanDeliveryTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.V1.ObanDeliveryTest.Domain do
  @moduledoc false

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1.ObanDeliveryTest.Probe)
  end
end

defmodule AshA2A.V1.ObanDeliveryTest.ReplyAgent do
  @moduledoc false
  # Real AshA2A.Protocol.Agent GenServer that completes every message
  # synchronously (zero mocks).
  use AshA2A.Protocol.Agent, name: "z4-oban-delivery-reply", description: "replies ok"

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context), do: {:reply, [AshA2A.Protocol.Part.Text.new("ok")]}
end

defmodule AshA2A.V1.ObanDeliveryTest.WebhookWorker do
  @moduledoc """
  Real `Oban.Worker` delivering a completed A2A task's wrapped v1.0 payload
  to the task's webhook.

  This is the host-integration composition for Oban-mediated push delivery:
  the job args carry the REAL payload taken from the real
  `AshA2A.A2ATransport.TaskEvents` event log of a task that really completed
  through the real `AshA2A.A2ATransport.Plug`, and `perform/1` hands it to
  the real `AshA2A.A2ATransport.PushDelivery.deliver/5` (SSRF-admitted
  connect, token + Bearer headers, HMAC signature, attempt recording). No
  stage of the path is stubbed.

  ## Pinned product finding (typed gap, not a mock)

  No product module composes these two halves today:
  `AshA2A.Delivery.Oban` carries *commands* (`AshA2A.Command` -> job args ->
  host worker -> `AshA2A.CommandBus`), while the wrapped v1.0
  `{"task": ...}` webhook delivery lives in `AshA2A.A2ATransport.PushDelivery`
  and runs in-process under the transport's `Task.Supervisor` with its own
  in-worker exponential backoff. This worker is the missing host glue, so
  the court below can witness the end-to-end durability semantics with the
  real engine -- and the gap itself is asserted nowhere as product behavior.
  """
  use Oban.Worker, queue: :z4_delivery, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    transport = String.to_existing_atom(args["transport"])
    push_opts = AshA2A.A2ATransport.TaskEvents.push_opts(transport)

    config = %{
      id: args["config"]["id"],
      task_id: args["config"]["task_id"],
      url: args["config"]["url"],
      token: args["config"]["token"]
    }

    AshA2A.A2ATransport.PushDelivery.deliver(
      transport,
      config,
      args["payload"],
      args["seq"],
      push_opts
    )
  end

  # Declared retry backoff: the second attempt is scheduled exactly
  # `backoff/1` seconds after a failed attempt, which the retry court
  # asserts against the real `oban_jobs.scheduled_at` column.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: 1}), do: 3
  def backoff(_job), do: 5
end

defmodule AshA2A.V1.ObanDeliveryTest do
  @moduledoc """
  Lane Z4 -- Oban delivery durability court. Everything below runs against a
  real PostgreSQL-backed `oban_jobs` table, a real `Oban` instance with a
  real RUNNING queue (no `:manual` drain, no `Oban.Testing.perform_job/2` --
  the real producers/executors claim and run every job), a real
  `AshA2A.A2ATransport` tree, and a real Bandit webhook receiver on
  loopback. No mocks.

  ## Pinned wiring finding (read up front)

  `AshA2A.Delivery.Oban` (lib/ash_a2a/delivery/oban.ex) is a *command*
  delivery adapter: `enqueue/3` serializes an admitted `AshA2A.Command` into
  job args for a host worker to reconstruct and re-admit through
  `AshA2A.CommandBus`. It has no notion of a completed A2A task, a webhook
  URL, or the wrapped v1.0 `{"task": ...}` payload. That payload's delivery
  lives in `AshA2A.A2ATransport.PushDelivery`, which the transport drives
  in-process (`Task.Supervisor` child + in-worker exponential backoff), not
  through Oban. So the composite "an Oban job delivers a completed task's
  wrapped v1.0 payload" has **no product subject**: the config IS reachable
  in-test (a real Oban boots below), and the gap is module semantics, not
  wiring. The court therefore witnesses the composite as a real host
  integration (`WebhookWorker` above: real engine + real
  `PushDelivery.deliver/5` + real receiver) and pins the real product
  semantics of each half in the same run.

  ## Court

    1. *(product subject)* `AshA2A.Delivery.Oban.enqueue/3` inserts a real
       job for a real `AshA2A.Command`; the real running queue executes the
       repo's real reference worker (`AshA2A.Test.Support.CommandWorker`),
       which reconstructs the command and commits a real receipt + a real
       fixture `Item`. The job row is asserted in its real terminal state
       (`completed`), polled through the real DB.

    2. *(a + d, host composition)* A real task really completes through the
       real transport; its real published payload is read back from the real
       `TaskEvents` log; a real delivery job is enqueued; the real queue
       executes it; the real receiver receives `{"task": ...}` with the
       notification token and a signature that verifies against the real
       signing secret, and the body equals the real stream/task wire shape
       byte-for-byte (`Jason`-equal to the log's payload, no `"final"`
       anywhere). The real attempt record shows `{:ok, 200}`.

    3. *(b, host composition)* A delivery job whose config points at a
       closed loopback port fails on the real connection-refused transport
       error; the worker returns `{:error, _}`; the real engine transitions
       the job to `retryable` and schedules the retry per the worker's
       declared `backoff/1` -- asserted against the real `oban_jobs` row
       (`state`, `attempt`, `scheduled_at`), i.e. real queue state.

    4. *(c, dedup, both legs)* Two enqueues of the same delivery key hold at
       most one live job: for the webhook leg the key is
       `(task_id, config_id)` under Oban's real unique support (second
       insert returns the same job with `conflict?` true and only one
       delivery ever executes); for the product subject the key is
       `(worker, command_id, fingerprint)` via
       `AshA2A.Delivery.Oban.unique_opts/0` (second enqueue is
       `deduplicated?` and the real queue executes the command exactly
       once). A same-`command_id`/different-fingerprint command is NOT
       absorbed -- two jobs -- pinning the real key shape.

  Needs a real, reachable PostgreSQL instance for `AshA2A.Test.Repo`
  (`config/test.exs`); `setup_all` checks that for real and raises with
  setup instructions rather than crashing opaquely. Only this file's own
  queue (`:z4_delivery`) is served, so the court cannot steal sibling
  Oban tests' jobs when the full suite runs.
  """

  use ExUnit.Case, async: false

  @moduletag :serial

  import Ecto.Query

  alias AshA2A.{Command, Delivery, Identity}
  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.A2ATransport.TaskEvents
  alias AshA2A.Authority.Grant
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.Fixture.{Item, ItemDomain}
  alias AshA2A.Test.Support.CommandWorker
  alias AshA2A.V1.ObanDeliveryTest.{Receiver, ReplyAgent, WebhookWorker}

  @oban_name AshA2A.V1.ObanDeliveryTest.Oban
  @queue :z4_delivery
  @capability_id "AshA2A.Test.Fixture.Item.create"
  @secret "z4-oban-delivery-signing-secret"

  setup_all do
    ensure_postgres_reachable!()

    {:ok, _} = Application.ensure_all_started(:postgrex)
    start_supervised!(AshA2A.Test.Repo)

    apply_oban_migration!()

    # Real Oban with a real RUNNING queue -- jobs are claimed and executed by
    # Oban's own producer/executor, not drained or driven by the test. The
    # Stager (default-on in every real deployment) is the machinery that
    # stages due `retryable`/`scheduled` jobs back to `available` -- measured
    # first-hand: with `plugins: false` it never runs (that setting also
    # disables leadership, and only the leader stages), so a retried job
    # stays `retryable` forever. `plugins: []` keeps leadership alive while
    # omitting the maintenance plugins.
    start_supervised!(
      {Oban,
       name: @oban_name,
       repo: AshA2A.Test.Repo,
       queues: [{@queue, [limit: 5]}],
       plugins: [],
       stager: [interval: 250]}
    )

    :ok
  end

  setup do
    %{
      suffix:
        Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <>
          "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    }
  end

  # -- 1. product subject: command delivery through the real engine -------------

  test "Delivery.Oban.enqueue/3 + real running queue executes CommandWorker: real receipt, real Item, job row completed",
       %{suffix: suffix} do
    label = "z4-cmd-#{suffix}"
    command = build_command("cmd-#{suffix}", label)

    assert {:ok, %Delivery{provider: :oban, status: :scheduled, provider_ref: job_id}} =
             Delivery.Oban.enqueue(CommandWorker, command,
               name: @oban_name,
               job_opts: [queue: @queue]
             )

    assert %{state: "completed"} = wait_for_job(job_id, "completed")

    assert {:ok, receipt} = AshA2A.ReceiptStore.Memory.fetch(command.command_id)
    assert receipt.status == :completed
    assert receipt.capability_id == @capability_id

    assert [%Item{label: ^label}] =
             Item |> Ash.read!(domain: ItemDomain) |> Enum.filter(&(&1.label == label))
  end

  # -- 2. (a) + (d): completed task's wrapped v1.0 payload delivered by a real job --

  test "(a) a delivery job enqueued for a completed task executes and delivers the wrapped v1.0 payload to the real webhook receiver",
       %{suffix: suffix} do
    %{task_id: task_id, seq: seq, payload: payload, transport: transport, hook: hook} =
      complete_task_and_payload(suffix)

    config = %{id: "cfg-z4-a", task_id: task_id, url: hook, token: "tok-z4-a"}

    args = %{
      "task_id" => task_id,
      "config_id" => config.id,
      "transport" => Atom.to_string(transport),
      "seq" => seq,
      "config" => %{id: config.id, task_id: task_id, url: hook, token: config.token},
      "payload" => payload
    }

    assert {:ok, job} = Oban.insert(@oban_name, WebhookWorker.new(args, queue: @queue))
    assert %{state: "completed"} = wait_for_job(job.id, "completed")

    assert_receive {:webhook, "POST", headers, body}, 5_000
    headers = Map.new(headers)

    assert headers["x-a2a-notification-token"] == "tok-z4-a"
    assert headers["content-type"] == "application/json"
    assert headers["x-a2a-delivery-id"] == "#{task_id}:cfg-z4-a:#{seq}"

    # Receiver-side HMAC verification against the real signing secret.
    assert :ok =
             AshA2A.A2ATransport.PushDelivery.verify_signature(
               @secret,
               headers["x-a2a-timestamp"],
               headers["x-a2a-signature"],
               body
             )

    assert {:error, :bad_signature} =
             AshA2A.A2ATransport.PushDelivery.verify_signature(
               @secret,
               headers["x-a2a-timestamp"],
               headers["x-a2a-signature"],
               body <> " "
             )

    # (d) The delivered body equals the real stream/task wire shape:
    # `{"task": ...}` with the terminal wire state, and no "final" anywhere.
    decoded = Jason.decode!(body)
    assert decoded == payload

    assert %{
             "task" => %{
               "id" => ^task_id,
               "status" => %{"state" => "TASK_STATE_COMPLETED"}
             }
           } = decoded

    refute Map.has_key?(decoded, "final")
    refute body =~ ~s("final")

    # Real delivery bookkeeping: exactly one real HTTP 200 attempt recorded.
    assert [%{attempt: 1, outcome: {:ok, 200}, config_id: "cfg-z4-a"}] =
             TaskEvents.attempts(transport, task_id)
  end

  # -- 3. (b): connection-refused URL -> retry scheduled per the declared backoff --

  test "(b) a failing receiver URL schedules a real retry per the declared backoff",
       %{suffix: suffix} do
    %{task_id: task_id, seq: seq, payload: payload, transport: transport} =
      complete_task_and_payload(suffix)

    fail_transport = start_transport(:"z4_transport_fail_#{suffix}", max_attempts: 1)

    # Nothing listens here: WebhookPolicy admits 127.0.0.1, the connect is
    # really refused.
    dead_url = "http://127.0.0.1:9/hook"

    config = %{id: "cfg-z4-b", task_id: task_id, url: dead_url, token: "tok-z4-b"}

    args = %{
      "task_id" => task_id,
      "config_id" => config.id,
      "transport" => Atom.to_string(fail_transport),
      "seq" => seq,
      "config" => %{id: config.id, task_id: task_id, url: dead_url, token: config.token},
      "payload" => payload
    }

    assert {:ok, job} = Oban.insert(@oban_name, WebhookWorker.new(args, queue: @queue))

    # The in-worker attempt really ran and really failed on the refused
    # connect (real delivery bookkeeping, not inference from job state).
    assert %{state: "retryable"} = wait_for_job(job.id, "retryable")

    assert [%{attempt: 1, outcome: {:transport_error, "connection refused"}, at: failed_at}] =
             wait_for_attempts(fail_transport, task_id, 1)

    # Real queue state: engine attempt 1 was consumed and the retry is
    # scheduled ~backoff(1) = 3s out, per the worker's declared backoff.
    retried = AshA2A.Test.Repo.get!(Oban.Job, job.id)
    assert retried.attempt == 1
    assert %DateTime{} = retried.scheduled_at

    delay = DateTime.diff(retried.scheduled_at, failed_at, :millisecond)
    assert delay in 2_500..3_500, "expected retry ~3s out, got #{inspect(delay)}ms"

    # The retry is real: the engine re-executes ~3s later and the worker
    # really fails against the dead URL again. (Each engine attempt re-runs
    # PushDelivery.deliver/5, so the recorded attempt number restarts at 1;
    # the ~3s gap between the two real failure records is the retry.)
    assert [
             %{attempt: 1, outcome: {:transport_error, "connection refused"}, at: first_at},
             %{attempt: 1, outcome: {:transport_error, "connection refused"}, at: second_at}
           ] = wait_for_attempts(fail_transport, task_id, 2)

    gap = DateTime.diff(second_at, first_at, :millisecond)
    assert gap in 2_000..6_000, "expected retry re-execution ~3s later, got #{inspect(gap)}ms"
  end

  # -- 4. (c): dedup -----------------------------------------------------------------

  test "(c) two enqueues of the same webhook delivery key hold at most one executing job",
       %{suffix: suffix} do
    %{task_id: task_id, seq: seq, payload: payload, transport: transport, hook: hook} =
      complete_task_and_payload(suffix)

    config = %{id: "cfg-z4-c", task_id: task_id, url: hook, token: "tok-z4-c"}

    args = %{
      "task_id" => task_id,
      "config_id" => config.id,
      "transport" => Atom.to_string(transport),
      "seq" => seq,
      "config" => %{id: config.id, task_id: task_id, url: hook, token: config.token},
      "payload" => payload
    }

    unique = [
      fields: [:args, :worker],
      keys: [:task_id, :config_id],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :completed, :suspended]
    ]

    assert {:ok, first} =
             Oban.insert(@oban_name, WebhookWorker.new(args, queue: @queue, unique: unique))

    assert {:ok, second} =
             Oban.insert(@oban_name, WebhookWorker.new(args, queue: @queue, unique: unique))

    assert second.id == first.id
    assert second.conflict? == true

    assert %{state: "completed"} = wait_for_job(first.id, "completed")

    # Exactly one real delivery for the two completions.
    assert [%{attempt: 1, outcome: {:ok, 200}, config_id: "cfg-z4-c"}] =
             TaskEvents.attempts(transport, task_id)

    assert [_one] = live_webhook_jobs(task_id, "cfg-z4-c")
    assert_receive {:webhook, "POST", _, _}, 5_000
    refute_receive {:webhook, _, _, _}, 300
  end

  test "(c) product subject: two enqueues of the same command hold one live job and execute exactly once",
       %{suffix: suffix} do
    label = "z4-dedup-#{suffix}"
    command = build_command("dedup-#{suffix}", label)

    assert {:ok, %Delivery{provider_ref: first_id} = first} =
             Delivery.Oban.enqueue(CommandWorker, command,
               name: @oban_name,
               job_opts: [queue: @queue]
             )

    assert first.metadata.deduplicated? == false

    assert {:ok, %Delivery{provider_ref: second_id} = second} =
             Delivery.Oban.enqueue(CommandWorker, command,
               name: @oban_name,
               job_opts: [queue: @queue]
             )

    assert second_id == first_id
    assert second.metadata.deduplicated? == true

    assert %{state: "completed"} = wait_for_job(first_id, "completed")

    # One live row for the delivery key, and the real queue executed the
    # command exactly once (one real Item, no duplicate execution).
    command_id = Identity.external(command.command_id)

    assert [_one] =
             AshA2A.Test.Repo.all(
               from(j in Oban.Job,
                 where: fragment("?->>'command_id' = ?", j.args, ^command_id),
                 where: j.state not in ["cancelled", "discarded"]
               )
             )

    assert [%Item{label: ^label}] =
             Item |> Ash.read!(domain: ItemDomain) |> Enum.filter(&(&1.label == label))
  end

  test "(c) pinned key shape: same command_id with different fingerprint is NOT absorbed",
       %{suffix: suffix} do
    a = build_command("keyshape-#{suffix}", "z4-key-a-#{suffix}")

    b =
      %{a | input: %{"label" => "z4-key-b-#{suffix}"}}
      |> then(&%{&1 | fingerprint: Command.fingerprint(&1)})

    refute a.fingerprint == b.fingerprint

    assert {:ok, %Delivery{provider_ref: a_id}} =
             Delivery.Oban.enqueue(CommandWorker, a, name: @oban_name, job_opts: [queue: @queue])

    assert {:ok, %Delivery{provider_ref: b_id} = b_delivery} =
             Delivery.Oban.enqueue(CommandWorker, b, name: @oban_name, job_opts: [queue: @queue])

    refute a_id == b_id
    assert b_delivery.metadata.deduplicated? == false
    assert length(live_command_jobs(a)) == 2
  end

  # -- fixtures ------------------------------------------------------------------

  defp start_receiver do
    EphemeralHttp.start!({Receiver, %{test: self()}}).base_url <> "/hook"
  end

  defp start_transport(name, extra_push) do
    # Keyword.merge, not `base ++ extra`: a later duplicate of
    # `max_attempts:` must WIN, since PushDelivery reads the push opts with
    # Keyword.get (first occurrence).
    start_supervised!(
      {AshA2A.A2ATransport,
       name: name,
       push:
         Keyword.merge(
           [
             allow_http: true,
             allow_cidrs: ["127.0.0.1/32"],
             signing_secret: @secret,
             max_attempts: 3,
             base_backoff_ms: 10
           ],
           extra_push
         )}
    )

    name
  end

  # Drives a real task to real completion through the real transport and
  # reads the REAL published payload (`{"task" => ...}`, final?) back from
  # the real TaskEvents log -- the exact body product's own push path would
  # deliver for this task.
  defp complete_task_and_payload(suffix) do
    agent = :"z4_oban_reply_#{suffix}"
    transport = start_transport(:"z4_transport_#{suffix}", [])

    start_supervised!({ReplyAgent, name: agent})

    hook = start_receiver()

    opts =
      TransportPlug.init(agent: agent, base_url: "http://x/a2a", transport: transport)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "message/send",
        "params" => %{"message" => message()}
      })

    conn =
      :post
      |> Plug.Test.conn("/", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> TransportPlug.call(opts)

    assert conn.status == 200

    %{"result" => %{"task" => %{"id" => task_id}}} = Jason.decode!(conn.resp_body)

    # The real event log holds the real wrapped payload the product's own
    # push path would deliver for this completed task.
    assert [{seq, "task", payload, true}] = TaskEvents.backlog(transport, task_id)

    %{task_id: task_id, seq: seq, payload: payload, transport: transport, hook: hook}
  end

  defp message do
    {:ok, encoded} = AshA2A.Protocol.JSON.encode(AshA2A.Protocol.Message.new_user("hello"))
    encoded
  end

  defp build_command(command_id, label) do
    principal = Identity.principal("subject-#{command_id}")
    {:ok, authority} = Grant.grant(principal, @capability_id)

    Command.new(@capability_id,
      command_id: command_id,
      agent_id: "agent-#{command_id}",
      principal_id: principal,
      authority: authority,
      input: %{label: label}
    )
  end

  defp live_webhook_jobs(task_id, config_id) do
    AshA2A.Test.Repo.all(
      from(j in Oban.Job,
        where: j.worker == "AshA2A.V1.ObanDeliveryTest.WebhookWorker",
        where: fragment("?->>'task_id' = ?", j.args, ^task_id),
        where: fragment("?->>'config_id' = ?", j.args, ^config_id),
        where: j.state not in ["cancelled", "discarded"]
      )
    )
  end

  defp live_command_jobs(command) do
    command_id = Identity.external(command.command_id)

    AshA2A.Test.Repo.all(
      from(j in Oban.Job,
        where: fragment("?->>'command_id' = ?", j.args, ^command_id),
        where: j.state not in ["cancelled", "discarded"]
      )
    )
  end

  defp wait_for_job(job_id, state, tries \\ 100)

  defp wait_for_job(job_id, state, tries) do
    job = AshA2A.Test.Repo.get!(Oban.Job, job_id)

    cond do
      job.state == state ->
        job

      job.state in ["discarded", "cancelled"] and state != "discarded" ->
        flunk("job #{job_id} reached #{job.state}, never #{state}")

      tries == 0 ->
        flunk("job #{job_id} never reached #{state}; last state #{job.state}")

      true ->
        Process.sleep(50)
        wait_for_job(job_id, state, tries - 1)
    end
  end

  defp wait_for_attempts(transport, task_id, n, tries \\ 100)

  defp wait_for_attempts(transport, task_id, n, tries) do
    attempts = TaskEvents.attempts(transport, task_id)

    cond do
      length(attempts) >= n ->
        attempts

      tries == 0 ->
        flunk("expected #{n} delivery attempts, got #{inspect(attempts)}")

      true ->
        Process.sleep(50)
        wait_for_attempts(transport, task_id, n, tries - 1)
    end
  end

  defp apply_oban_migration! do
    case Ecto.Migrator.up(
           AshA2A.Test.Repo,
           20_260_913_000_001,
           AshA2A.Test.Repo.Migrations.AddObanJobsTable,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end

  defp ensure_postgres_reachable! do
    repo_config = Application.fetch_env!(:ash_a2a, AshA2A.Test.Repo)

    connect_opts = [
      hostname: Keyword.fetch!(repo_config, :hostname),
      port: Keyword.fetch!(repo_config, :port),
      username: Keyword.fetch!(repo_config, :username),
      password: Keyword.fetch!(repo_config, :password),
      database: Keyword.fetch!(repo_config, :database),
      timeout: 2_000,
      connect_timeout: 2_000
    ]

    case Postgrex.start_link(connect_opts) do
      {:ok, pid} ->
        GenServer.stop(pid)
        :ok

      {:error, reason} ->
        raise """
        Real Postgres not reachable at #{connect_opts[:hostname]}:#{connect_opts[:port]}/#{connect_opts[:database]} \
        for AshA2A.Test.Repo (test/ash_a2a_v1_oban_delivery_test.exs).
        Reason: #{inspect(reason)}

        This court needs a real, dedicated local Postgres instance to run
        Oban's real `oban_jobs` table against (real engine, no mocked queue).
        Start one and re-run, e.g.:

          docker run --rm -p 55432:5432 -e POSTGRES_PASSWORD=postgres \\
            -e POSTGRES_DB=ash_a2a_test postgres:16

        then: MIX_BUILD_ROOT=_build-laneZ4 mix test test/ash_a2a_v1_oban_delivery_test.exs --include serial
        """
    end
  end
end
