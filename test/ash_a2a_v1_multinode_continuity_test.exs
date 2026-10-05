defmodule AshA2A.V1MultinodeContinuityTest.Conversation do
  @moduledoc """
  Real fixture resource, private to this test file (per the proven
  `ash_a2a_v1_context_continuity_test.exs` pattern), for the A2A v1.0
  multi-node task-continuity court (`test/ash_a2a_v1_multinode_continuity_test.exs`).

  Same shape as the context-continuity fixture: one generic `:converse` action
  requiring `:say` and `:topic`. A turn supplying `:say` only pauses the task
  at `TASK_STATE_INPUT_REQUIRED`, so the durable store holds a genuinely
  continuable (non-terminal) task for the fresh-agent courts to resume.
  """

  use Ash.Resource,
    domain: AshA2A.V1MultinodeContinuityTest.ConversationDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  actions do
    action :converse, :map do
      argument(:say, :string, allow_nil?: false)
      argument(:topic, :string, allow_nil?: false)

      run(fn input, _context ->
        {:ok, %{"say" => input.arguments.say, "topic" => input.arguments.topic}}
      end)
    end
  end

  a2a do
    skill(:converse, :converse, consequence: :observe)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.ConversationDomain do
  @moduledoc "Real fixture domain for `AshA2A.V1MultinodeContinuityTest.Conversation`."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.V1MultinodeContinuityTest.Conversation)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.ConversationAgent do
  @moduledoc """
  Real `AshA2A.Agent` GenServer (transport runtime: owner-scoped tasks,
  off-mailbox workers) over the private fixture resource. `execution:
  [mode: :inline]` matches the serialized shape every other plug-level
  fixture in this suite uses.
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.V1MultinodeContinuityTest.Conversation,
    name: "v1_multinode_continuity_conversation_agent",
    require_authenticated_caller: false,
    execution: [mode: :inline]
end

defmodule AshA2A.V1MultinodeContinuityTest.StreamAgent do
  @moduledoc """
  Real `AshA2A.Agent` whose `handle_message/2` returns a lazy `{:stream,
  enumerable}` that nobody enumerates -- so the task is persisted
  `TASK_STATE_WORKING` and *stays* that way until the agent is killed, which
  is exactly the "in-memory agent lost mid-stream" state the resubscribe
  court needs (the proven `ash_a2a_v1_taskstore_durability_test.exs`
  StreamAgent pattern).
  """

  use AshA2A.Agent,
    resource_or_domain: AshA2A.Test.Fixture.Echo,
    name: "v1_multinode_continuity_stream_agent",
    require_authenticated_caller: false

  @impl AshA2A.Protocol.Agent
  def handle_message(_message, _context) do
    {:stream, Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("chunk #{i}") end)}
  end
end

defmodule AshA2A.V1MultinodeContinuityTest.AuthChain do
  @moduledoc """
  Real plug chain for the restart courts: bearer auth middleware ->
  owner-scoped transport plug over real HTTP.

  The store-backed `tasks/list` flip (lane F16) is only observable for a
  real principal: an anonymous caller never lists (fail-closed), so the
  restart courts exercise `alice`/`bob` through the same proven bearer
  scheme + `verify/3` shape the owner-scope court
  (`test/ash_a2a_v1_owner_scope_test.exs`) uses.
  """

  def init(opts), do: opts

  def call(conn, %{auth: auth, transport_plug: transport_plug}) do
    conn
    |> AshA2A.Protocol.Plug.Auth.call(auth)
    |> then(fn conn ->
      if conn.halted do
        conn
      else
        AshA2A.Transport.Plug.call(conn, transport_plug)
      end
    end)
  end
end

defmodule AshA2A.V1MultinodeContinuityTest do
  @moduledoc """
  A2A v1.0 horizontal-scaling / multi-node task-continuity court (lane Z8):
  the story the durable store claims (`AshA2A.TaskStore.Ekv`'s moduledoc) --
  a task created through a REAL agent+plug on node A is visible and
  continuable after the in-memory agent is lost, when the durable store plus
  a SECOND agent process reads the same store. Zero mocks: real Bandit
  loopback listeners serving `AshA2A.A2ATransport.Plug`, real
  `AshA2A.A2ATransport` supervision trees, real `AshA2A.Agent` GenServers, a
  real on-disk EKV store, and -- for the store tier -- a real 2-node EKV
  cluster (one member on the primary BEAM node, one on a genuinely separate
  OS-process peer started via OTP's real `:peer` module), per the proven
  pattern in `test/ash_a2a/receipt_store_ekv_crossnode_test.exs` +
  `test/support/multinode_ekv_owner.ex`.

  Verified read architecture (READ-ONLY first, pinned here as behavior):

    * `AshA2A.Protocol.Agent.State.get_task/2` (`lib/ash_a2a/protocol/agent/state.ex`)
      IS a read-through cache: in-memory hit first, `mod.get(ref, task_id)`
      fallthrough on miss. `AshA2A.Transport.Runtime.continue/6` and
      `get_task_for/3` both go through it, so a FRESH agent process whose
      in-memory task map is empty finds every task the store holds. The
      agent-level horizontal story HOLDS for interactive tasks.
    * The deliberate gaps this court pins as gap witnesses:
      (1) CLOSED (lane F16): `AshA2A.Transport.Runtime.list_tasks_for/3` used
      to page the IN-MEMORY map only, so `tasks/list` on a fresh agent
      returned nothing even though the store held the tasks. It now merges
      the store's tasks into the page (in-memory wins on id collision, union
      by owner key) before the single `Filter.apply` + pagination, so
      `tasks/list` read-through sees every task the store holds for the
      caller — court (b) pins the flipped wire behavior.
      (2) A mid-flight stream is node-local (`metadata[:stream]` is redacted
      at rest by EKV and the enumerating process died with the lost agent):
      the persisted task is visible and resubscribable on the fresh agent,
      but continuing it is refused typed (`:task_in_progress`, the
      `state != :working` guard in `Runtime.continue/6`) and the stream never
      progresses by itself on the new agent. The honest close: the fresh
      agent can still cancel the task, and that wire cancel publishes the
      final TaskEvents event that terminates the resubscribed SSE stream.

  The agent restart legs run as LOCAL restarts (fresh GenServer, same
  process-name-free store tuple) because the gap is store-fallback-shaped --
  the agent tier's behavior is identical for a restarted process on the same
  node; the STORE tier (where the second real node lives) is exercised on a
  genuine 2-node EKV cluster with cross-node reads of plug-created tasks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_solo
  @moduletag :v1_conformance

  alias AshA2A.A2ATransport.Plug, as: TransportPlug
  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.JSON
  alias AshA2A.Protocol.{Message, Part}
  alias AshA2A.TaskStore.Ekv, as: EkvStore
  alias AshA2A.Test.EphemeralHttp
  alias AshA2A.Test.MultinodeEkvOwner
  alias AshA2A.V1MultinodeContinuityTest.{ConversationAgent, StreamAgent}

  @schemes %{"bearer" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}}

  # Real verify callback (owner-scope court shape): the bearer token names
  # the user; the verified identity keys the owner via
  # `AshA2A.Transport.Principal.key/1` -> `"sub:<token>"`.
  def verify("bearer", token, _conn), do: {:ok, %{sub: token, token: "raw-credential-of-" <> token}}

  defp auth_chain(agent, transport) do
    AshA2A.V1MultinodeContinuityTest.AuthChain.init(%{
      auth: AshA2A.Protocol.Plug.Auth.init(schemes: @schemes, verify: &__MODULE__.verify/3),
      transport_plug:
        AshA2A.Transport.Plug.init(agent: agent, base_url: "http://x/a2a", transport: transport)
    })
  end

  # Real HTTP auth chain -> transport plug, like `plug_and_transport/1` but
  # with the bearer middleware in front, so wire callers carry a verified
  # principal (`alice`/`bob`) instead of `:anonymous`.
  defp plug_and_transport_auth(agent) do
    uniq = System.unique_integer([:positive, :monotonic])
    transport = :"a2a_transport_v1mncont_auth_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})

    EphemeralHttp.start!(
      {AshA2A.V1MultinodeContinuityTest.AuthChain, auth_chain(agent, transport)}
    ).base_url
  end

  # -- authenticated wire helpers ----------------------------------------------

  # The anonymous caller is the real no-auth shape: no Authorization header,
  # so the auth middleware leaves `conn.private[:a2a][:auth]` unset.
  defp rpc_as(url, :anonymous, method, params) do
    rpc(url, method, params)
  end

  defp rpc_as(url, user, method, params) do
    body = rpc_envelope(method, params)

    Req.post!(url,
      json: Map.put(body, "params", params),
      headers: [{"authorization", "Bearer " <> user}],
      retry: false,
      receive_timeout: 10_000
    )
    |> Map.fetch!(:body)
    |> case do
      m when is_map(m) -> m
      bin when is_binary(bin) -> Jason.decode!(bin)
    end
  end

  defp turn_as(url, user, opts) do
    params = %{"message" => user_message(Keyword.get(opts, :data), Keyword.get(opts, :task_id))}

    params =
      if ctx = Keyword.get(opts, :context_id),
        do: Map.put(params, "contextId", ctx),
        else: params

    url
    |> rpc_as(user, "message/send", params)
    |> result_task()
  end

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    already_alive? = Node.alive?()

    unless already_alive? do
      primary_name = :"ash_a2a_v1_mn_cont_primary_#{System.pid()}"
      {:ok, _pid} = Node.start(primary_name, :shortnames)
    end

    on_exit(fn ->
      if not already_alive? and Node.alive?() do
        Node.stop()
      end
    end)

    :ok
  end

  setup do
    %{cookie: Node.get_cookie(), host: peer_host(), code_paths: :code.get_path()}
  end

  defp peer_host do
    Node.self() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist()
  end

  # Near-verbatim copy of `AshA2A.ReceiptStoreEkvCrossnodeTest.start_real_peer/3`
  # (private functions cannot be called across modules).
  defp start_real_peer(host, cookie, code_paths) do
    peer_name = :"ash_a2a_v1_mn_cont_peer_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: peer_name,
        host: host,
        args: [~c"-setcookie", Atom.to_charlist(cookie)]
      })

    assert :ok = :rpc.call(peer_node, :code, :add_pathsz, [code_paths])

    {peer_pid, peer_node}
  end

  # Same real, empirically-found reason `AshA2A.MultinodeClusterTest`'
  # @moduledoc documents: `:peer.stop/1` on a `:peer.start_link/1`-started
  # peer must be called FROM THE SAME process that called `start_link`, so
  # cleanup lives in each test's own `try/after`, not `on_exit/1`.
  defp stop_if_alive(peer_pid) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)

    :ok
  end

  defp fresh_ekv_name do
    :"ash_a2a_v1_mn_cont_ekv_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp fresh_data_dir(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_v1_mn_cont_#{tag}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # cluster_size: 1 -- one local EKV member, for the agent-restart courts.
  defp ekv_local(tag) do
    name = fresh_ekv_name()
    data_dir = fresh_data_dir(tag)
    start_supervised!(EkvStore.child_spec(name: name, data_dir: data_dir))
    %{name: name, data_dir: data_dir, store: EkvStore.task_store(name)}
  end

  # -- wire helpers (proven `ash_a2a_v1_context_continuity_test.exs` shape) ---

  defp rpc_envelope(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  defp rpc(url, method, params) do
    body = rpc_envelope(method, params)

    resp_body =
      Req.post!(url, json: Map.put(body, "params", params), retry: false, receive_timeout: 10_000)
      |> Map.fetch!(:body)

    if is_map(resp_body), do: resp_body, else: Jason.decode!(resp_body)
  end

  defp user_message(data, task_id) do
    parts = if data, do: [Part.Data.new(data)], else: [Part.Text.new("go")]
    message = struct(Message.new_user(parts), task_id: task_id)
    {:ok, encoded} = JSON.encode(message)
    encoded
  end

  defp turn(url, opts) do
    params = %{"message" => user_message(Keyword.get(opts, :data), Keyword.get(opts, :task_id))}
    params = if ctx = Keyword.get(opts, :context_id), do: Map.put(params, "contextId", ctx), else: params

    url
    |> rpc("message/send", params)
    |> result_task()
  end

  defp result_task(%{"result" => result}) do
    task = get_in(result, ["task"]) || result

    assert is_map(task) and is_binary(task["id"]), "no task in message/send result"
    task
  end

  defp plug_and_transport(agent) do
    uniq = System.unique_integer([:positive, :monotonic])
    transport = :"a2a_transport_v1mncont_#{uniq}"
    start_supervised!({AshA2A.A2ATransport, name: transport})

    EphemeralHttp.start!(
      {TransportPlug, agent: agent, base_url: "http://x/a2a", transport: transport}
    ).base_url
  end

  # -- SSE streaming helpers (proven `ash_a2a_v1_sse_replay_test.exs` shape) --

  defp open_streaming(url, method, params) do
    parent = self()

    spawn(fn ->
      Req.post!(url,
        json: %{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => method,
          "params" => params
        },
        retry: false,
        receive_timeout: 15_000,
        into: fn {:data, data}, acc ->
          send(parent, {:chunk, self(), data})
          {:cont, acc}
        end
      )

      send(parent, {:stream_closed, self()})
    end)
  end

  defp collect_until_closed(pid, acc) do
    receive do
      {:chunk, ^pid, data} -> collect_until_closed(pid, acc <> data)
      {:stream_closed, ^pid} -> acc
    after
      15_000 -> flunk("resubscribed stream did not close after the fresh-agent cancel")
    end
  end

  defp parse_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")

      for "data: " <> json <- Enum.filter(lines, &String.starts_with?(&1, "data: ")) do
        Jason.decode!(json)["result"]
      end
    end)
  end

  # -- fixture conversation turn helper ---------------------------------------

  defp converse(data, opts) do
    turn(Keyword.fetch!(opts, :url), Keyword.put(opts, :data, data))
  end

  defp eventually(fun, attempts \\ 100, sleep_ms \\ 50)
  defp eventually(_fun, 0, _sleep_ms), do: false

  defp eventually(fun, attempts, sleep_ms) do
    if fun.(), do: true, else: Process.sleep(sleep_ms) && eventually(fun, attempts - 1, sleep_ms)
  end

  # ===========================================================================
  # Court (a): the STORE tier across two real nodes -- a task created through
  # a real agent+plug on node A is visible on real node B, and a second agent
  # process over the same cluster continues it to a terminal state that is
  # again visible from node B.
  # ===========================================================================
  describe "two-node store tier" do
    test "a plug-created task on the primary replicates to the peer; a second agent continues it; the terminal state is visible from the peer",
         %{cookie: cookie, host: host, code_paths: code_paths} do
      assert Node.alive?(), "primary node must be a real distributed node by this point"

      {peer_pid, peer_node} = start_real_peer(host, cookie, code_paths)

      try do
        assert peer_node in Node.list()

        ekv_name = fresh_ekv_name()
        data_dir_primary = fresh_data_dir("a_primary")
        data_dir_peer = fresh_data_dir("a_peer")

        base_opts = [name: ekv_name, cluster_size: 2, wait_for_quorum: :timer.seconds(25)]

        # The peer's real EKV cluster member starts first (from a real,
        # persistent peer-owned process -- see MultinodeEkvOwner's @moduledoc),
        # then the primary's member blocks on the real 2-of-2 quorum until the
        # peer joins. Both wait for each other and proceed together.
        test_pid = self()

        _owner =
          Node.spawn(peer_node, MultinodeEkvOwner, :start_ekv_member_and_wait, [
            Keyword.put(base_opts, :data_dir, data_dir_peer),
            test_pid
          ])

        start_supervised!(
          EkvStore.child_spec(Keyword.put(base_opts, :data_dir, data_dir_primary))
        )

        assert_receive {:ekv_member_started, ^peer_node, sup_pid}, 30_000
        assert node(sup_pid) == peer_node

        # --- node A: real agent + plug over the 2-node cluster. ---------------
        store = EkvStore.task_store(ekv_name)
        {:ok, agent_a_pid} = ConversationAgent.start_link(name: :v1mncont_agent_a, task_store: store)
        url_a = plug_and_transport(:v1mncont_agent_a)

        task1 = converse(%{"say" => "hail"}, url: url_a, context_id: "ctx-v1mn-a")

        assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
        task_id = task1["id"]
        assert task1["contextId"] == "ctx-v1mn-a"

        # --- node B: the same task, read through the peer's own EKV member. ---
        # Wait for the task's FINAL paused state, not mere existence: the
        # store also carries the turn's intermediate `:working` write, and an
        # existence-only wait reads that mid-flight snapshot (observed
        # `:working` on this exact read under load).
        assert eventually(fn ->
                 match?(
                   {:ok, %AshA2A.Protocol.Task{status: %{state: :input_required}}},
                   :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000)
                 )
               end),
               "the plug-created task must replicate to the peer's real EKV member"

        assert {:ok, peer_task} = :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000)
        assert peer_task.id == task_id
        assert peer_task.context_id == "ctx-v1mn-a"
        assert peer_task.status.state == :input_required

        # --- the in-memory agent A is lost. -----------------------------------
        GenServer.stop(agent_a_pid)
        assert Process.whereis(:v1mncont_agent_a) == nil

        # --- a SECOND agent process over the SAME store cluster. --------------
        {:ok, agent_b_pid} = ConversationAgent.start_link(name: :v1mncont_agent_b, task_store: store)
        url_b = plug_and_transport(:v1mncont_agent_b)

        # Its in-memory task map is genuinely empty; the read falls through to
        # the store cluster.
        assert %State{tasks: tasks_b} = :sys.get_state(agent_b_pid)
        assert tasks_b == %{}

        %{"result" => fetched} = rpc(url_b, "tasks/get", %{"id" => task_id})
        assert fetched["id"] == task_id
        assert fetched["contextId"] == "ctx-v1mn-a"
        assert fetched["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
        assert length(fetched["history"]) == 2

        # --- and the second agent CONTINUES the stored task on the wire. ------
        task2 = turn(url_b, task_id: task_id, data: %{"say" => "hail", "topic" => "weather"})

        assert task2["id"] == task_id
        assert task2["status"]["state"] == "TASK_STATE_COMPLETED"
        assert task2["contextId"] == "ctx-v1mn-a"
        assert length(task2["history"]) == 4

        # --- the terminal state is again visible from the peer. ---------------
        assert eventually(fn ->
                 case :erpc.call(peer_node, EkvStore, :get, [ekv_name, task_id], 10_000) do
                   {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} -> true
                   _ -> false
                 end
               end),
               "the second agent's terminal write must replicate to the peer"

        cleanup_agents([:v1mncont_agent_a, :v1mncont_agent_b])
      after
        stop_if_alive(peer_pid)
      end
    end
  end

  # ===========================================================================
  # Court (b): the AGENT tier, local restart -- after the in-memory agent is
  # lost, a fresh agent over the same durable store answers tasks/get,
  # LISTS the stored task (store-backed read-through, lane F16), continues
  # it, and the terminal state lists too — pagination over the merged set.
  # ===========================================================================
  describe "agent-restart tier" do
    test "a fresh agent answers tasks/get, lists the stored task, and continues it; the terminal state lists too",
         %{cookie: _cookie, host: _host, code_paths: _code_paths} do
      %{name: ekv_name, store: store} = ekv_local("b")
      {:ok, agent_a_pid} = ConversationAgent.start_link(name: :v1mncont_b_agent_a, task_store: store)
      url_a = plug_and_transport_auth(:v1mncont_b_agent_a)

      # alice creates the non-terminal task; the owner key (`"ash_a2a.owner"`
      # = "sub:alice") is what persists — the Z9 at-rest owner-survival pin.
      task1 = turn_as(url_a, "alice", context_id: "ctx-v1mn-b")
      assert task1["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      task_id = task1["id"]

      # bob's own task in the same store, so merged owner-scoping is real.
      bob_task = turn_as(url_a, "bob", context_id: "ctx-v1mn-b-bob")
      assert bob_task["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"

      # The durable store holds both tasks, each carrying its owner key.
      assert {:ok, persisted} = EkvStore.get(ekv_name, task_id)
      assert persisted.status.state == :input_required
      assert persisted.metadata["ash_a2a.owner"] == "sub:alice"

      assert {:ok, bob_persisted} = EkvStore.get(ekv_name, bob_task["id"])
      assert bob_persisted.metadata["ash_a2a.owner"] == "sub:bob"

      # --- the in-memory agent is lost. ---------------------------------------
      GenServer.stop(agent_a_pid)
      assert Process.whereis(:v1mncont_b_agent_a) == nil

      # Cold read-through: a state struct with an empty in-memory map and only
      # the store tuple finds the task (the exact read path
      # `Runtime.continue/6` and `get_task_for/3` take).
      cold = %State{module: ConversationAgent, task_store: store}
      assert {:ok, %AshA2A.Protocol.Task{id: ^task_id}} = State.get_task(cold, task_id)

      # --- a fresh agent process over the same store. --------------------------
      {:ok, agent_b_pid} =
        ConversationAgent.start_link(name: :v1mncont_b_agent_b, task_store: store)

      assert %State{tasks: tasks_b} = :sys.get_state(agent_b_pid)
      assert tasks_b == %{}

      url_b = plug_and_transport_auth(:v1mncont_b_agent_b)

      # The anonymous shape is the REAL no-auth shape (owner-scope court
      # definition): the transport reached with NO auth middleware in front,
      # so no verified identity exists in conn.private.
      url_b_anon = plug_and_transport(:v1mncont_b_agent_b)

      %{"result" => fetched} = rpc_as(url_b, "alice", "tasks/get", %{"id" => task_id})
      assert fetched["id"] == task_id
      assert fetched["contextId"] == "ctx-v1mn-b"
      assert fetched["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      assert length(fetched["history"]) == 2

      # FLIPPED PIN (lane F16): the transport's owner-scoped tasks/list is now
      # store-backed read-through (`Runtime.list_tasks_for/3` merges the
      # store's tasks into the page before `Filter.apply`), so the fresh agent
      # with an empty in-memory map lists the persisted task for its owner.
      # Owner-scoping holds over the merged set: alice sees exactly her task
      # (never bob's), bob sees exactly his, and anonymous still lists
      # nothing at all.
      %{"result" => %{"tasks" => [listed], "totalSize" => 1}} =
        rpc_as(url_b, "alice", "tasks/list", %{})

      assert listed["id"] == task_id
      assert listed["contextId"] == "ctx-v1mn-b"
      assert listed["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      # Same scrubbing as the in-memory path: no internal keys on the wire.
      refute Map.has_key?(listed, "metadata")

      %{"result" => %{"tasks" => [bob_listed], "totalSize" => 1}} =
        rpc_as(url_b, "bob", "tasks/list", %{})

      assert bob_listed["id"] == bob_task["id"]

      assert %{"result" => %{"tasks" => [], "totalSize" => 0}} =
               rpc(url_b_anon, "tasks/list", %{})

      # The raw agent-level list (the Protocol path) IS store-backed but
      # UNSCOPED: a fresh agent's {:list_tasks, params} delegates to the
      # store's list_all/2 and pages everything — the owner-scoped wire
      # surface above is the gate.
      assert {:ok, page} = GenServer.call(:v1mncont_b_agent_b, {:list_tasks, %{}})
      assert page.total_size == 2

      # --- the fresh agent continues the stored task. --------------------------
      task2 = turn_as(url_b, "alice", task_id: task_id, data: %{"say" => "hail", "topic" => "weather"})
      assert task2["id"] == task_id
      assert task2["status"]["state"] == "TASK_STATE_COMPLETED"
      assert task2["contextId"] == "ctx-v1mn-b"
      assert length(task2["history"]) == 4

      # FLIPPED PIN, terminal leg: after the continuation, tasks/list on the
      # same fresh agent still lists exactly alice's one task — now the
      # terminal state (the in-memory write overrode the store copy;
      # totalSize is the merged count, still 1).
      %{"result" => %{"tasks" => [terminal], "totalSize" => 1}} =
        rpc_as(url_b, "alice", "tasks/list", %{})

      assert terminal["id"] == task_id
      assert terminal["status"]["state"] == "TASK_STATE_COMPLETED"

      # The store now holds the second agent's terminal write.
      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :completed}}} =
               EkvStore.get(ekv_name, task_id)

      cleanup_agents([:v1mncont_b_agent_a, :v1mncont_b_agent_b])
    end

    test "pagination over the merged (in-memory + store) set is exact: no dup, no gap", _ctx do
      %{store: store} = ekv_local("b_walk")
      {:ok, agent_a_pid} =
        ConversationAgent.start_link(name: :v1mncont_bwalk_agent_a, task_store: store)

      url_a = plug_and_transport_auth(:v1mncont_bwalk_agent_a)

      # Three durable tasks from alice on the original agent, distinct
      # contexts so each is its own task in the store.
      created =
        for i <- 1..3 do
          t = turn_as(url_a, "alice", context_id: "ctx-v1mn-bwalk-#{i}")
          assert t["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
          t["id"]
        end

      # --- the in-memory agent is lost. ---------------------------------------
      GenServer.stop(agent_a_pid)

      # --- a fresh agent over the same store: in-memory map empty, merged set
      # is the store's three tasks. -------------------------------------------
      {:ok, _agent_b_pid} =
        ConversationAgent.start_link(name: :v1mncont_bwalk_agent_b, task_store: store)

      url_b = plug_and_transport_auth(:v1mncont_bwalk_agent_b)

      # Walk pageSize=2 pages: page 1 is exactly 2 tasks with a live cursor,
      # page 2 the remainder with the "" terminator, union == the created ids
      # with no duplicate and no gap, and every page carries the pre-
      # pagination merged total (3).
      %{"result" => page1} = rpc_as(url_b, "alice", "tasks/list", %{"pageSize" => 2})
      assert %{"tasks" => t1, "totalSize" => 3, "nextPageToken" => tok1} = page1
      assert length(t1) == 2
      assert is_binary(tok1) and tok1 != ""

      %{"result" => page2} =
        rpc_as(url_b, "alice", "tasks/list", %{"pageSize" => 2, "pageToken" => tok1})

      assert %{"tasks" => t2, "totalSize" => 3, "nextPageToken" => ""} = page2
      assert length(t2) == 1

      walked = Enum.map(t1 ++ t2, & &1["id"])
      assert Enum.uniq(walked) == walked, "no duplicate task across pages"
      assert Enum.sort(walked) == Enum.sort(created), "no gap: the walk covers exactly the merged set"

      cleanup_agents([:v1mncont_bwalk_agent_a, :v1mncont_bwalk_agent_b])
    end
  end

  # ===========================================================================
  # Court (c): the SSE/resubscribe tier -- a persisted non-terminal (mid-
  # stream, node-local) task is resubscribable on the fresh agent; continuing
  # it there is refused typed (`:task_in_progress`); the fresh agent's wire
  # cancel publishes the final event that terminates the resubscribed stream.
  # ===========================================================================
  describe "sse-resubscribe tier" do
    test "a mid-stream task lost with its agent is resubscribable on a fresh agent; continuation is refused typed; the fresh agent's cancel closes the stream",
         %{cookie: _cookie, host: _host, code_paths: _code_paths} do
      %{name: ekv_name, store: store} = ekv_local("c")
      {:ok, agent_a_pid} = StreamAgent.start_link(name: :v1mncont_c_agent_a, task_store: store)

      # Real agent run producing a stream task; nobody enumerates the returned
      # stream, so the task is persisted :working and stays that way (the
      # wrapped stream is node-local and dies with agent A).
      {:ok, %AshA2A.Protocol.Task{id: task_id} = task} =
        StreamAgent.call(:v1mncont_c_agent_a, AshA2A.Protocol.Message.new_user("stream me"))

      assert task.status.state == :working

      # The store's persisted copy has the node-local stream reference redacted
      # at rest (EKV's documented at-rest redaction).
      assert {:ok, persisted} = EkvStore.get(ekv_name, task_id)
      refute Map.has_key?(persisted.metadata, :stream)

      # --- the in-memory agent is lost mid-stream. ----------------------------
      GenServer.stop(agent_a_pid)
      assert Process.whereis(:v1mncont_c_agent_a) == nil

      # --- a fresh agent process over the same store. -------------------------
      {:ok, _agent_b_pid} = StreamAgent.start_link(name: :v1mncont_c_agent_b, task_store: store)
      url_b = plug_and_transport(:v1mncont_c_agent_b)

      # The fresh agent answers tasks/get for the persisted task.
      %{"result" => fetched} = rpc(url_b, "tasks/get", %{"id" => task_id})
      assert fetched["id"] == task_id
      assert fetched["status"]["state"] == "TASK_STATE_WORKING"

      # Wire resubscribe on the FRESH agent: the first SSE frame is the
      # persisted task snapshot (S3.1.6), served through the same store
      # read-through.
      open_streaming(url_b, "tasks/resubscribe", %{"id" => task_id})
      {conn_pid, snapshot_result, acc} = await_snapshot_frame()

      assert %{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_WORKING"}}} =
               snapshot_result

      # GAP WITNESS (by design, see moduledoc): continuing the :working task
      # on the fresh agent is refused typed -- the stream is node-local and
      # not resumable (the DurableServer continuity gap, GitHub issue #8).
      continuation =
        GenServer.call(:v1mncont_c_agent_b, {:message, Message.new_user("resume"), task_id: task_id})

      assert {:error, %{code: :task_in_progress}} = continuation

      # The honest close: the fresh agent can cancel the task, and the wire
      # cancel publishes the final TaskEvents event that terminates the
      # resubscribed stream with a terminal frame.
      %{"result" => canceled} = rpc(url_b, "tasks/cancel", %{"id" => task_id})
      assert canceled["id"] == task_id
      assert canceled["status"]["state"] == "TASK_STATE_CANCELED"

      body = collect_until_closed(conn_pid, acc)
      frames = parse_sse(body)

      assert [%{"task" => %{"id" => ^task_id, "status" => %{"state" => "TASK_STATE_WORKING"}}} | rest] =
               frames

      assert Enum.any?(rest, fn
               %{"task" => %{"status" => %{"state" => "TASK_STATE_CANCELED"}}} -> true
               _ -> false
             end)

      # The fresh agent's cancel is durable too.
      assert {:ok, %AshA2A.Protocol.Task{status: %{state: :canceled}}} =
               EkvStore.get(ekv_name, task_id)

      cleanup_agents([:v1mncont_c_agent_a, :v1mncont_c_agent_b])
    end
  end

  # Receives chunks from the (anonymous-pid) resubscribe connection until the
  # first task frame appears; returns `{conn_pid, snapshot_result, bytes_so_far}`
  # so the cancel-frame collector can resume with the full prefix.
  defp await_snapshot_frame(acc \\ "") do
    receive do
      {:chunk, pid, data} ->
        acc = acc <> data

        case Enum.find(parse_sse(acc), fn result ->
               match?(%{"task" => %{"id" => _}}, result)
             end) do
          nil -> await_snapshot_frame(acc)
          result -> {pid, result, acc}
        end
    after
      5_000 -> flunk("no snapshot frame from the resubscribed stream")
    end
  end

  defp cleanup_agents(names) do
    for name <- names do
      if pid = Process.whereis(name) do
        GenServer.stop(pid)
      end
    end
  end
end
