defmodule AshA2A.V1TaskStoreDurabilityTest do
  @moduledoc """
  A2A v1.0 conformance court, lane X9: task persistence across the pluggable
  `AshA2A.Protocol.TaskStore` seam (v1.0: tasks survive agent/process restarts
  when a durable store is configured).

  Five courts against the real subjects (`AshA2A.Protocol.TaskStore` behaviour,
  `AshA2A.Protocol.TaskStore.ETS` reference impl, `AshA2A.TaskStore.Ekv`
  durable impl, `AshA2A.Protocol.Agent.State` put_task/get_task delegation),
  driven through real agent GenServer runs and a real on-disk EKV instance.
  Zero mocks.

  Spec-vs-reality notes:

    * `AshA2A.TaskStore.Ekv` redacts `"a2a.auth"` and the node-local `:stream`
      metadata key at rest (its moduledoc documents this). The lane contract
      phrase "contains neither a2a.auth/owner keys" is NOT the implementation
      contract: `"ash_a2a.owner"` is deliberately PERSISTED so ownership
      checks still hold after a restart (a continuation rebinds auth from the
      current call). These courts pin the implementation contract.
    * The ETS reference store does NOT redact anything — it is the in-memory
      reference impl, so a stored `:stream` enumerable round-trips verbatim.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :v1_conformance

  alias AshA2A.Protocol.Agent.State
  alias AshA2A.Protocol.Task
  alias AshA2A.Protocol.TaskStore
  alias AshA2A.TaskStore.Ekv, as: EkvStore

  # --- Real agents (defined per the proven prior-art pattern in
  # --- ash_a2a_v1_artifact_streaming_test.exs: `use AshA2A.Agent` over the
  # --- real Echo fixture resource, `handle_message/2` genuinely overridden).

  defmodule ReplyAgent do
    @moduledoc "Real agent whose `handle_message/2` returns `{:reply, parts}`."
    use AshA2A.Agent,
      resource_or_domain: AshA2A.Test.Fixture.Echo,
      name: "v1_taskstore_durability_reply_agent"

    @impl AshA2A.Protocol.Agent
    def handle_message(message, _context) do
      {:reply, [AshA2A.Protocol.Part.Text.new("echo: " <> AshA2A.Protocol.Message.text(message))]}
    end
  end

  defmodule StreamAgent do
    @moduledoc "Real agent whose `handle_message/2` returns `{:stream, enumerable}`."
    use AshA2A.Agent,
      resource_or_domain: AshA2A.Test.Fixture.Echo,
      name: "v1_taskstore_durability_stream_agent"

    @impl AshA2A.Protocol.Agent
    def handle_message(_message, _context) do
      {:stream,
       Stream.map(1..3, fn i -> AshA2A.Protocol.Part.Text.new("chunk #{i}") end)}
    end
  end

  # --- Shared fixtures -------------------------------------------------------

  defp unique_suffix, do: System.unique_integer([:positive])

  defp ekv_setup(context_tag) do
    id = unique_suffix()
    name = :"v1_taskstore_durability_ekv_#{context_tag}_#{id}"
    data_dir = Path.join(System.tmp_dir!(), "v1_taskstore_durability_#{context_tag}_#{id}")
    File.rm_rf!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    ekv_pid = start_supervised!(EkvStore.child_spec(name: name, data_dir: data_dir))
    %{name: name, data_dir: data_dir, pid: ekv_pid}
  end

  defp ets_setup(context_tag) do
    id = unique_suffix()
    name = :"v1_taskstore_durability_ets_#{context_tag}_#{id}"
    start_supervised!({TaskStore.ETS, [name: name]})
    name
  end

  defp start_agent!(module, store_tuple) do
    {:ok, pid} = module.start_link(name: module, task_store: store_tuple)
    pid
  end

  # Tasks written through the real `State.put_task/2` delegation seam (the
  # same call the agent GenServer makes on every write), with hand-set
  # distinct timestamps so `Filter.apply` ordering is deterministic.
  defp seed_task(store_mod, store_ref, attrs) do
    state = %State{module: ReplyAgent, task_store: {store_mod, store_ref}}

    task = %Task{
      id: attrs.id,
      context_id: attrs.context_id,
      status: %AshA2A.Protocol.Task.Status{
        state: attrs.state,
        timestamp: attrs.timestamp,
        message: nil
      },
      history: attrs.history,
      artifacts: attrs.artifacts,
      metadata: Map.get(attrs, :metadata, %{})
    }

    # Written through the same State.put_task delegation the agent GenServer
    # uses on every write (court (d) seeding).
    _updated_state = State.put_task(state, task)
    task
  end

  defp history_for(text) do
    [
      AshA2A.Protocol.Message.new_user(text),
      AshA2A.Protocol.Message.new_agent("re: " <> text)
    ]
  end

  defp artifact_for(name) do
    AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new(name)], name: name)
  end

  defp ts(hour, minute) do
    DateTime.new!(Date.new!(2026, 10, 1), Time.new!(hour, minute, 0))
  end

  # The IDENTICAL task terms are written to both stores so a parity failure
  # can only come from store semantics, never from fixture randomness.
  defp seed_tasks() do
    [
      %{
        id: "tsk-seed-a",
        context_id: "ctx-1",
        state: :working,
        timestamp: ts(1, 0),
        history: history_for("a"),
        artifacts: [artifact_for("a")]
      },
      %{
        id: "tsk-seed-b",
        context_id: "ctx-1",
        state: :completed,
        timestamp: ts(2, 0),
        history: history_for("b"),
        artifacts: [artifact_for("b")]
      },
      %{
        id: "tsk-seed-c",
        context_id: "ctx-2",
        state: :completed,
        timestamp: ts(3, 0),
        history: history_for("c"),
        artifacts: [artifact_for("c")]
      },
      %{
        id: "tsk-seed-d",
        context_id: "ctx-2",
        state: :failed,
        timestamp: ts(4, 0),
        history: history_for("d"),
        artifacts: [artifact_for("d")]
      },
      %{
        id: "tsk-seed-e",
        context_id: "ctx-1",
        state: :completed,
        timestamp: ts(5, 0),
        history: history_for("e"),
        artifacts: [artifact_for("e")]
      }
    ]
  end

  defp write_seed_set(store_mod, store_ref, tasks_attrs) do
    for attrs <- tasks_attrs do
      seed_task(store_mod, store_ref, attrs)
    end
  end

  describe "court (a): ETS store fidelity over real agent runs" do
    test "a completed task from a real agent run round-trips with full fidelity" do
      table = ets_setup("fidelity")
      start_agent!(ReplyAgent, {TaskStore.ETS, table})

      {:ok, %Task{} = returned} = ReplyAgent.call(ReplyAgent, AshA2A.Protocol.Message.new_user("hi"))

      assert returned.status.state == :completed
      assert length(returned.history) == 2
      assert length(returned.artifacts) == 1

      assert {:ok, stored} = TaskStore.ETS.get(table, returned.id)
      # Full structural fidelity: the store holds exactly what the run produced.
      assert stored == returned
      assert stored.metadata == %{}
    end

    test "a stream task from a real agent run round-trips minus stream keys" do
      table = ets_setup("stream")
      start_agent!(StreamAgent, {TaskStore.ETS, table})

      {:ok, %Task{} = returned} =
        StreamAgent.call(StreamAgent, AshA2A.Protocol.Message.new_user("stream me"))

      assert returned.status.state == :working
      # The runtime stamped the live enumerable into metadata before the write.
      assert Map.has_key?(returned.metadata, :stream)

      assert {:ok, stored} = TaskStore.ETS.get(table, returned.id)

      # ETS (reference impl) does not redact: the enumerable is in the stored
      # struct too. Fidelity is asserted minus stream keys, per contract.
      assert Map.has_key?(stored.metadata, :stream)
      assert Task.strip_stream_metadata(stored) == Task.strip_stream_metadata(returned)
    end

    test "a real agent run is gettable through the State.get_task store-fallback delegation" do
      table = ets_setup("delegation")
      start_agent!(ReplyAgent, {TaskStore.ETS, table})

      {:ok, %Task{id: task_id} = returned} =
        ReplyAgent.call(ReplyAgent, AshA2A.Protocol.Message.new_user("delegate"))

      # A FRESH agent state (as after a restart) has an empty in-memory map:
      # the read must fall through to the store.
      fresh_state = %State{module: ReplyAgent, task_store: {TaskStore.ETS, table}}
      assert {:ok, ^returned} = State.get_task(fresh_state, task_id)
      assert {:error, :not_found} = State.get_task(fresh_state, "tsk-never-existed")
    end
    end

  describe "court (b): EKV store fidelity across a REAL store-process restart" do
    test "tasks from real agent runs survive stop/restart of the EKV child at the same data_dir" do
      %{name: name, data_dir: data_dir, pid: ekv_pid} = ekv_setup("restart")
      start_agent!(ReplyAgent, EkvStore.task_store(name))
      start_agent!(StreamAgent, EkvStore.task_store(name))

      {:ok, %Task{} = completed} =
        ReplyAgent.call(ReplyAgent, AshA2A.Protocol.Message.new_user("persist me"))

      {:ok, %Task{} = streaming} =
        StreamAgent.call(StreamAgent, AshA2A.Protocol.Message.new_user("persist stream"))

      assert completed.status.state == :completed
      assert streaming.status.state == :working

      # --- REAL restart: stop the EKV store child, restart it, re-read.
      assert :ok = stop_supervised({EKV, name})

      # The store supervisor we started is really gone before the restart.
      # (A `whereis(name)` probe here was VACUOUS: EKV registers no process
      # under the instance name -- its processes are named :"#{name}_ekv_*"
      # -- so the nil check passed whether or not the store had stopped.)
      refute Process.alive?(ekv_pid)

      start_supervised!(EkvStore.child_spec(name: name, data_dir: data_dir))

      # The restarted store really answers again (aliveness proven by a read,
      # not a registration probe: EKV's process naming is its own affair).
      assert {:ok, %AshA2A.Protocol.Task{}} = EkvStore.get(name, completed.id)

      # Full fidelity after restart (stream key is redacted at rest by EKV).
      assert {:ok, stored_completed} = EkvStore.get(name, completed.id)
      assert stored_completed == completed

      assert {:ok, stored_streaming} = EkvStore.get(name, streaming.id)
      refute Map.has_key?(stored_streaming.metadata, :stream)
      assert Task.strip_stream_metadata(stored_streaming) ==
               Task.strip_stream_metadata(streaming)

      # The State.get_task delegation reads the restarted store for a fresh agent.
      fresh_state = %State{module: ReplyAgent, task_store: EkvStore.task_store(name)}
      assert {:ok, %Task{id: id}} = State.get_task(fresh_state, completed.id)
      assert id == completed.id
    end
  end

  describe "court (c): EKV at-rest redaction" do
    test "a2a.auth and node-local stream never reach the persisted bytes; owner key is retained" do
      %{name: name, data_dir: data_dir} = ekv_setup("redaction")

      owner = AshA2A.Transport.Runtime.owner_key()

      secret_task = %Task{
        id: "tsk-secret",
        context_id: "ctx-secret",
        status: %AshA2A.Protocol.Task.Status{
          state: :working,
          timestamp: ts(6, 0),
          message: nil
        },
        history: history_for("secret"),
        artifacts: [artifact_for("secret")],
        metadata: %{
          "a2a.auth" => %{"token" => "SECRET-BEARER-TOKEN"},
          owner => "principal:u1",
          :stream => Stream.map([1], & &1),
          "keep" => "me"
        }
      }

      # Written through the real State.put_task -> store.put delegation seam.
      state = %State{module: ReplyAgent, task_store: EkvStore.task_store(name)}
      _ = State.put_task(state, secret_task)

      # Raw EKV read (not through the store facade): what is actually persisted.
      persisted = EKV.get(name, "a2a_task/tsk-secret")
      refute Map.has_key?(persisted.metadata, "a2a.auth")
      refute Map.has_key?(persisted.metadata, :stream)
      assert persisted.metadata["keep"] == "me"
      # Spec-vs-reality: the owner key is deliberately persisted (see moduledoc).
      assert persisted.metadata[owner] == "principal:u1"

      # And the token bytes are absent from the on-disk files themselves.
      assert :ok = stop_supervised({EKV, name})

      on_disk =
        data_dir
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map_join(&File.read!/1)

      refute on_disk =~ "SECRET-BEARER-TOKEN"
      refute on_disk =~ "a2a.auth"
      assert on_disk =~ "principal:u1"
    end
  end

  describe "court (d): Filter.apply semantics over stored tasks (ETS/EKV parity)" do
    test "status filter, pagination, and truncation are identical between the two stores" do
      ets_table = ets_setup("filter")
      %{name: ekv_name} = ekv_setup("filter")
      tasks_attrs = seed_tasks()
      write_seed_set(TaskStore.ETS, ets_table, tasks_attrs)
      write_seed_set(EkvStore, ekv_name, tasks_attrs)

      # --- status filter: only :working tasks, identical ids.
      assert {:ok, ets_page} = TaskStore.ETS.list_all(ets_table, status: :working)
      assert {:ok, ekv_page} = EkvStore.list_all(ekv_name, status: :working)
      assert Enum.map(ets_page.tasks, & &1.id) == ["tsk-seed-a"]
      assert Enum.map(ekv_page.tasks, & &1.id) == ["tsk-seed-a"]
      assert ets_page.total_size == 1
      assert ekv_page.total_size == 1

      # --- pagination parity: page_size 2 walking the same token chain.
      ets_pages = walk_pages(TaskStore.ETS, ets_table, page_size: 2)
      ekv_pages = walk_pages(EkvStore, ekv_name, page_size: 2)

      assert length(ets_pages) == 3
      assert length(ekv_pages) == 3

      assert [ets_pages, ekv_pages]
             |> Enum.zip()
             |> Enum.all?(fn {a, b} ->
               Enum.map(a.tasks, & &1.id) == Enum.map(b.tasks, & &1.id) and
                 a.next_page_token == b.next_page_token and
                 a.total_size == b.total_size
             end)

      # Full ordering: status.timestamp descending across the walk.
      assert ets_pages |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id) ==
               ["tsk-seed-e", "tsk-seed-d", "tsk-seed-c", "tsk-seed-b", "tsk-seed-a"]

      # Filter.apply defaults: history cleared, artifacts stripped unless asked.
      assert Enum.all?(ets_pages |> Enum.flat_map(& &1.tasks), &(&1.history == []))
      assert Enum.all?(ekv_pages |> Enum.flat_map(& &1.tasks), &(&1.history == []))

      # --- context filter parity.
      assert {:ok, ets_ctx} = TaskStore.ETS.list_all(ets_table, context_id: "ctx-2")
      assert {:ok, ekv_ctx} = EkvStore.list_all(ekv_name, context_id: "ctx-2")
      assert Enum.map(ets_ctx.tasks, & &1.id) == ["tsk-seed-d", "tsk-seed-c"]
      assert Enum.map(ekv_ctx.tasks, & &1.id) == ["tsk-seed-d", "tsk-seed-c"]

      # --- history_length + include_artifacts parity (non-default opts).
      opts = [history_length: 1, include_artifacts: true]

      assert {:ok, ets_h} = TaskStore.ETS.list_all(ets_table, opts)
      assert {:ok, ekv_h} = EkvStore.list_all(ekv_name, opts)

      assert [ets_h.tasks, ekv_h.tasks]
             |> Enum.zip()
             |> Enum.all?(fn {a, b} -> a == b end)

      # history_length: 1 keeps the LAST history entry (the agent reply).
      [last_entry] = hd(ets_h.tasks).history
      assert %AshA2A.Protocol.Message{role: :agent} = last_entry
      assert AshA2A.Protocol.Message.text(last_entry) == "re: e"
      refute Enum.empty?(hd(ets_h.tasks).artifacts)

      # --- invalid page token is rejected identically.
      assert {:error, :invalid_page_token} =
               TaskStore.ETS.list_all(ets_table, page_token: "tsk-nope")

      assert {:error, :invalid_page_token} = EkvStore.list_all(ekv_name, page_token: "tsk-nope")
    end
  end

  defp walk_pages(store_mod, store_ref, opts) do
    walk_pages(store_mod, store_ref, opts, nil, [])
  end

  # Pages accumulate in reverse walk order.
  defp walk_pages(store_mod, store_ref, opts, token, acc) do
    {:ok, page} = store_mod.list_all(store_ref, Keyword.put(opts, :page_token, token))
    pages = [page | acc]

    case page.next_page_token do
      "" -> Enum.reverse(pages)
      next -> walk_pages(store_mod, store_ref, opts, next, pages)
    end
  end

  describe "court (e): TaskStore behaviour contract (both stores implement the behaviour)" do
    test "all 9 callbacks are declared; required ones in both stores; optional ones per impl" do
      callbacks = TaskStore.behaviour_info(:callbacks)
      assert length(callbacks) == 9

      optional = TaskStore.behaviour_info(:optional_callbacks)

      assert MapSet.new(optional) ==
               MapSet.new([
                 {:list_all, 2},
                 {:set_push_config, 2},
                 {:get_push_config, 3},
                 {:list_push_configs, 2},
                 {:delete_push_config, 3}
               ])

      required = callbacks -- optional
      assert MapSet.new(required) == MapSet.new([get: 2, put: 2, delete: 2, list: 2])

      for mod <- [TaskStore.ETS, EkvStore] do
        # function_exported?/3 reads false for a loaded-but-not-yet-claimed
        # module (the same trap AshA2A.Protocol.Agent.State exports?/3 guards).
        Code.ensure_loaded!(mod)

        # Every required callback is really exported by both stores.
        for {fun, arity} <- required do
          assert function_exported?(mod, fun, arity),
                 "#{inspect(mod)} does not export required callback #{fun}/#{arity}"
        end
      end

      # ETS (reference impl) exports ALL optional callbacks, including the
      # four push-config ones; the agent's State delegation uses those when
      # present and falls back to the in-memory map when absent.
      for {fun, arity} <- optional do
        assert function_exported?(TaskStore.ETS, fun, arity)
      end

      # Spec-vs-reality: `module_info(:attributes)[:behaviour]` is NOT a
      # reliable "declares the behaviour" probe — for the ETS store it lists
      # only [GenServer] despite the source `@behaviour AshA2A.Protocol.TaskStore`
      # (the `use GenServer` attribute wins the attribute slot). Ekv, which is
      # not a GenServer, does carry it.
      assert AshA2A.Protocol.TaskStore in (EkvStore.module_info(:attributes)[:behaviour] || [])

      # Spec-vs-reality: Ekv implements the optional list_all/2 but NOT the
      # push-config callbacks — an explicitly optional, documented absence
      # (State falls back to its in-memory push_config map for those).
      assert function_exported?(EkvStore, :list_all, 2)
      refute function_exported?(EkvStore, :set_push_config, 2)
      refute function_exported?(EkvStore, :get_push_config, 3)
      refute function_exported?(EkvStore, :list_push_configs, 2)
      refute function_exported?(EkvStore, :delete_push_config, 3)
    end
  end
end
