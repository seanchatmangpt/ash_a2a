defmodule AshA2A.TaskStoreContract do
  @moduledoc """
  Shared contract for `AshA2A.Protocol.TaskStore` implementations.

      defmodule MyStoreTest do
        use AshA2A.TaskStoreContract, store: MyStore

        # Must return a fresh, isolated store ref (starting any real
        # collaborator under start_supervised!).
        def start_store(tag), do: ...
      end

  Semantics are extracted from `ash_a2a_v1_taskstore_durability_test.exs`
  (court d: Filter.apply parity; court e: behaviour surface) plus CRUD and
  push-config round-trips. No mocks: every store runs for real.
  """

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote do
      use ExUnit.Case, async: false

      alias AshA2A.Protocol.Task
      alias AshA2A.Protocol.PushNotificationConfig

      @store unquote(store)

      defp contract_ts(hour), do: DateTime.new!(Date.new!(2026, 10, 1), Time.new!(hour, 0, 0))

      defp contract_task(id, ctx, state, hour) do
        %Task{
          id: id,
          context_id: ctx,
          status: %Task.Status{state: state, timestamp: contract_ts(hour), message: nil},
          history: [
            AshA2A.Protocol.Message.new_user("q " <> id),
            AshA2A.Protocol.Message.new_agent("re: " <> id)
          ],
          artifacts: [AshA2A.Protocol.Artifact.new([AshA2A.Protocol.Part.Text.new(id)], name: id)],
          metadata: %{"keep" => "me"}
        }
      end

      defp contract_seed(ref) do
        for {id, ctx, state, hour} <- [
              {"tsk-a", "ctx-1", :working, 1},
              {"tsk-b", "ctx-1", :completed, 2},
              {"tsk-c", "ctx-2", :completed, 3},
              {"tsk-d", "ctx-2", :failed, 4},
              {"tsk-e", "ctx-1", :completed, 5}
            ] do
          :ok = @store.put(ref, contract_task(id, ctx, state, hour))
        end
      end

      defp contract_walk(ref, opts), do: contract_walk(ref, opts, nil, [])

      defp contract_walk(ref, opts, token, acc) do
        {:ok, page} = @store.list_all(ref, Keyword.put(opts, :page_token, token))

        case page.next_page_token do
          "" -> Enum.reverse([page | acc])
          next -> contract_walk(ref, opts, next, [page | acc])
        end
      end

      test "contract: put/get round-trips and overwrite replaces" do
        ref = start_store("crud")
        task = contract_task("tsk-1", "ctx-1", :working, 1)

        assert {:error, :not_found} = @store.get(ref, "tsk-1")
        assert :ok = @store.put(ref, task)
        assert {:ok, got} = @store.get(ref, "tsk-1")
        assert got == task

        done = %{task | status: %{task.status | state: :completed, timestamp: contract_ts(2)}}
        assert :ok = @store.put(ref, done)
        assert {:ok, %Task{status: %{state: :completed}}} = @store.get(ref, "tsk-1")
      end

      test "contract: delete is idempotent" do
        ref = start_store("delete")
        :ok = @store.put(ref, contract_task("tsk-1", "ctx-1", :working, 1))
        assert :ok = @store.delete(ref, "tsk-1")
        assert {:error, :not_found} = @store.get(ref, "tsk-1")
        assert :ok = @store.delete(ref, "tsk-1")
      end

      test "contract: list/2 filters by context" do
        ref = start_store("list")
        contract_seed(ref)
        assert {:ok, tasks} = @store.list(ref, "ctx-2")
        assert tasks |> Enum.map(& &1.id) |> Enum.sort() == ["tsk-c", "tsk-d"]
        assert {:ok, []} = @store.list(ref, "ctx-none")
      end

      test "contract: list_all filter, pagination and truncation follow Task.Filter" do
        ref = start_store("filter")
        contract_seed(ref)

        assert {:ok, working} = @store.list_all(ref, status: :working)
        assert Enum.map(working.tasks, & &1.id) == ["tsk-a"]
        assert working.total_size == 1

        pages = contract_walk(ref, page_size: 2)
        assert length(pages) == 3

        assert pages |> Enum.flat_map(& &1.tasks) |> Enum.map(& &1.id) ==
                 ["tsk-e", "tsk-d", "tsk-c", "tsk-b", "tsk-a"]

        assert Enum.all?(Enum.flat_map(pages, & &1.tasks), &(&1.history == []))

        assert {:ok, ctx2} = @store.list_all(ref, context_id: "ctx-2")
        assert Enum.map(ctx2.tasks, & &1.id) == ["tsk-d", "tsk-c"]

        assert {:ok, h} = @store.list_all(ref, history_length: 1, include_artifacts: true)
        [last] = hd(h.tasks).history
        assert AshA2A.Protocol.Message.text(last) == "re: tsk-e"
        refute Enum.empty?(hd(h.tasks).artifacts)

        assert {:error, :invalid_page_token} = @store.list_all(ref, page_token: "tsk-nope")
      end

      test "contract: stores are isolated from each other" do
        a = start_store("iso-a")
        b = start_store("iso-b")
        :ok = @store.put(a, contract_task("tsk-only-a", "ctx-1", :working, 1))
        assert {:ok, _} = @store.get(a, "tsk-only-a")
        assert {:error, :not_found} = @store.get(b, "tsk-only-a")
      end

      test "contract: push config set/get/list/delete" do
        ref = start_store("push")

        c1 = %PushNotificationConfig{id: "c1", task_id: "tsk-1", url: "https://x.test/1"}

        c2 = %PushNotificationConfig{
          id: "c2",
          task_id: "tsk-1",
          url: "https://x.test/2",
          token: "t"
        }

        other = %PushNotificationConfig{id: "c1", task_id: "tsk-2", url: "https://x.test/3"}

        assert {:ok, ^c1} = @store.set_push_config(ref, c1)
        assert {:ok, ^c2} = @store.set_push_config(ref, c2)
        assert {:ok, ^other} = @store.set_push_config(ref, other)

        assert {:ok, ^c1} = @store.get_push_config(ref, "tsk-1", "c1")
        assert {:ok, listed} = @store.list_push_configs(ref, "tsk-1")
        assert listed |> Enum.map(& &1.id) |> Enum.sort() == ["c1", "c2"]

        replaced = %{c1 | url: "https://x.test/new"}
        assert {:ok, _} = @store.set_push_config(ref, replaced)
        assert {:ok, ^replaced} = @store.get_push_config(ref, "tsk-1", "c1")

        assert :ok = @store.delete_push_config(ref, "tsk-1", "c1")
        assert {:error, :not_found} = @store.get_push_config(ref, "tsk-1", "c1")
        assert :ok = @store.delete_push_config(ref, "tsk-1", "c1")
        assert {:ok, ^other} = @store.get_push_config(ref, "tsk-2", "c1")
      end

      test "contract: behaviour surface is exported" do
        Code.ensure_loaded!(@store)

        for {fun, arity} <- AshA2A.Protocol.TaskStore.behaviour_info(:callbacks) do
          assert function_exported?(@store, fun, arity),
                 "#{inspect(@store)} missing #{fun}/#{arity}"
        end
      end
    end
  end
end
