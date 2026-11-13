# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Cluster.Handover do
  @moduledoc """
  Cluster handover events and the peer rehydration path.

  When `AshA2A.Cluster.DrainManager` lands a task's execution frame durably
  (`AshA2A.Cluster.Checkpoint.land/4`), it emits a cluster handover event so
  surviving peers know work is suspended and adoptable. The event travels
  two ways:

    * `[:ash_a2a, :cluster, :handover]` telemetry, always;
    * a `Phoenix.PubSub` broadcast of
      `{:ash_a2a_cluster_handover, %{task_id: _, source_node: _, reason: _}}`
      on the topic configured under `config :ash_a2a, :cluster_pubsub`
      (`{pubsub_name, topic}`), when configured.

  Rehydration, though, does not depend on catching the in-flight event: the
  durable checkpoint IS the handover. A fresh (or surviving) peer runs
  `rehydrate/2` against the same `AshA2A.TaskStore.Ekv` `:data_dir` -- the
  multinode read-through mechanics -- finds every checkpointed task, resumes
  it from its stored frame, and writes the completed task back with the
  checkpoint envelope cleared. Zero-drop is then a property of durable
  storage, not of event delivery.
  """

  alias AshA2A.Cluster.Checkpoint
  alias AshA2A.Protocol.Task

  @result_metadata_key "a2a.cluster.result"
  @default_topic "ash_a2a:cluster"

  @type store :: Checkpoint.store()
  @type resume_fun :: (Task.t(), frame :: term() -> {:ok, term()} | {:error, term()})

  @doc "Metadata key under which a rehydrated task's result is stored."
  @spec result_metadata_key() :: String.t()
  def result_metadata_key, do: @result_metadata_key

  @doc """
  Emits a cluster handover event for `task_id`.

  Always `:ok`; telemetry fires unconditionally, PubSub broadcasts only when
  `config :ash_a2a, :cluster_pubsub` is set.
  """
  @spec emit(String.t(), keyword()) :: :ok
  def emit(task_id, meta \\ []) when is_binary(task_id) do
    event =
      %{
        task_id: task_id,
        source_node: Keyword.get(meta, :source_node, node()),
        reason: Keyword.get(meta, :reason, :drain),
        checkpointed_at: Keyword.get(meta, :checkpointed_at)
      }

    :telemetry.execute([:ash_a2a, :cluster, :handover], %{count: 1}, event)

    case pubsub() do
      {pubsub_name, topic} when is_atom(pubsub_name) and pubsub_name != nil ->
        Phoenix.PubSub.broadcast(pubsub_name, topic, {:ash_a2a_cluster_handover, event})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Every durably checkpointed (suspended, adoptable) task in `store`.

  Pages through the store's `list_all/2` with page tokens -- no silent
  truncation. A store without `list_all/2` yields
  `{:error, {:unsupported, :list_all}}`.
  """
  @spec list_checkpointed(store()) :: {:ok, [Task.t()]} | {:error, term()}
  def list_checkpointed({store_mod, store_ref}) do
    if Code.ensure_loaded?(store_mod) and function_exported?(store_mod, :list_all, 2) do
      collect_pages(store_mod, store_ref, nil, [])
    else
      {:error, {:unsupported, :list_all}}
    end
  end

  defp collect_pages(store_mod, store_ref, token, acc) do
    opts = [page_size: 500] ++ if(token, do: [page_token: token], else: [])

    case store_mod.list_all(store_ref, opts) do
      {:ok, %{tasks: tasks, next_page_token: next}} ->
        acc = acc ++ Enum.filter(tasks, &Checkpoint.checkpointed?/1)

        if next in [nil, ""],
          do: {:ok, acc},
          else: collect_pages(store_mod, store_ref, next, acc)

      {:error, _} = error ->
        error

      other ->
        {:error, {:unexpected_list_all, other}}
    end
  end

  @doc """
  Resumes every checkpointed task in `store` through `resume_fun`.

  `resume_fun` receives the suspended task and its stored execution frame
  and returns `{:ok, result}` when the remaining work concluded. The adopted
  task is written back `:completed` with its result in metadata under
  `"a2a.cluster.result"` and the checkpoint envelope cleared. Each task is
  claimed (see `rehydrate_one/4`) before `resume_fun` runs, so two peers
  cannot both resume it.

  A `resume_fun` `{:error, reason}` (or raise/throw/exit) releases the claim
  and leaves the checkpoint envelope intact (the task stays suspended and
  adoptable) and is collected instead of raised.
  """
  @spec rehydrate(store(), resume_fun()) :: {:ok, [map()]} | {:error, [map()]}
  def rehydrate(store, resume_fun, opts \\ []) when is_function(resume_fun, 2) do
    case list_checkpointed(store) do
      {:error, reason} ->
        {:error, [%{task_id: nil, reason: reason}]}

      {:ok, checkpointed} ->
        {resumed, failed} =
          Enum.reduce(checkpointed, {[], []}, fn task, {resumed, failed} ->
            case rehydrate_one(store, task, resume_fun, opts) do
              {:ok, entry} -> {[entry | resumed], failed}
              {:error, %{reason: :already_claimed}} -> {resumed, failed}
              {:error, entry} -> {resumed, [entry | failed]}
            end
          end)

        case failed do
          [] -> {:ok, Enum.reverse(resumed)}
          _ -> {:error, Enum.reverse(failed)}
        end
    end
  end

  @claim_key "a2a.cluster.claim"
  @default_claim_ttl_ms 60_000

  @doc """
  Resumes a single checkpointed task through `resume_fun`, effect-once.

  Before resuming, the task is claimed compare-and-set style: under a
  cluster-wide `:global.trans/3` lock keyed by task id, the task is re-read
  from the store and must still carry its checkpoint envelope and no live
  claim; the claim (node, unique ref, expiry) is then written. A loser sees
  `{:error, %{reason: :already_claimed}}` (or `:not_checkpointed` once the
  winner completed) and never calls `resume_fun`. A claim expires after
  `:claim_ttl_ms` (default 60_000) so a peer that died mid-resume does not
  strand the task.
  """
  @spec rehydrate_one(store(), Task.t(), resume_fun(), keyword()) ::
          {:ok, %{task_id: String.t(), result: term()}} | {:error, map()}
  def rehydrate_one(store, %Task{} = task, resume_fun, opts \\ [])
      when is_function(resume_fun, 2) do
    ttl = Keyword.get(opts, :claim_ttl_ms, @default_claim_ttl_ms)

    case claim(store, task.id, ttl) do
      {:ok, claimed} ->
        with {:ok, envelope} <- Checkpoint.envelope(claimed),
             {:ok, result} <- safe_resume(resume_fun, claimed, envelope["frame"]) do
          # Restore the checkpointed generation (never below what the store holds)
          # and bump it once for the completion mutation, so the stale-write
          # guard in the stores admits it.
          gen = max(claimed.generation || 1, envelope["generation"] || 1) + 1

          completed =
            claimed
            |> Checkpoint.cleared()
            |> then(&%{&1 | generation: gen})
            |> then(&%{&1 | metadata: Map.delete(&1.metadata, @claim_key)})
            |> then(&%{&1 | status: AshA2A.Protocol.Task.Status.new(:completed)})
            |> put_result(result)

          case complete_fenced(store, claimed, completed) do
            :ok ->
              :telemetry.execute(
                [:ash_a2a, :cluster, :handover, :completed],
                %{count: 1},
                %{task_id: task.id, node: node()}
              )

              {:ok, %{task_id: task.id, result: result}}

            {:error, reason} ->
              {:error, %{task_id: task.id, reason: reason}}
          end
        else
          {:error, reason} ->
            release_claim(store, task.id, claim_ref(claimed))
            {:error, %{task_id: task.id, reason: reason}}

          :error ->
            release_claim(store, task.id, claim_ref(claimed))
            {:error, %{task_id: task.id, reason: :missing_checkpoint_envelope}}
        end

      {:error, reason} ->
        {:error, %{task_id: task.id, reason: reason}}
    end
  end

  defp claim({store_mod, store_ref}, task_id, ttl) do
    :global.trans({{:ash_a2a_rehydrate, task_id}, self()}, fn ->
      with {:ok, current} <- store_mod.get(store_ref, task_id),
           true <- Checkpoint.checkpointed?(current) and not Task.terminal?(current),
           :ok <- claim_free(current) do
        claimed = %{
          current
          | metadata:
              Map.put(current.metadata, @claim_key, %{
                "node" => node(),
                "ref" => Base.encode16(:crypto.strong_rand_bytes(8)),
                "expires_at_ms" => System.system_time(:millisecond) + ttl
              })
        }

        :ok = store_mod.put(store_ref, claimed)
        {:ok, claimed}
      else
        false -> {:error, :not_checkpointed}
        {:error, :not_found} -> {:error, :not_checkpointed}
        {:error, _} = error -> error
      end
    end)
  end

  defp claim_free(%Task{metadata: metadata}) do
    case Map.get(metadata, @claim_key) do
      %{"expires_at_ms" => exp} when is_integer(exp) ->
        if exp > System.system_time(:millisecond), do: {:error, :already_claimed}, else: :ok

      _ ->
        :ok
    end
  end

  defp claim_ref(%Task{metadata: metadata}),
    do: get_in(metadata || %{}, [@claim_key, "ref"])

  # Fencing token: the claim ref written at claim time must still be the one
  # in the store, so a slow first runner whose claim expired (and was taken by
  # a peer) can neither complete nor release the peer's live claim.
  defp release_claim({store_mod, store_ref}, task_id, ref) do
    :global.trans({{:ash_a2a_rehydrate, task_id}, self()}, fn ->
      with {:ok, current} <- store_mod.get(store_ref, task_id),
           true <- claim_ref(current) == ref do
        store_mod.put(store_ref, %{current | metadata: Map.delete(current.metadata, @claim_key)})
      end
    end)

    :ok
  end

  defp complete_fenced({store_mod, store_ref}, claimed, completed) do
    :global.trans({{:ash_a2a_rehydrate, claimed.id}, self()}, fn ->
      with {:ok, current} <- store_mod.get(store_ref, claimed.id),
           true <- claim_ref(current) == claim_ref(claimed) do
        :ok = store_mod.put(store_ref, completed)

        case store_mod.get(store_ref, claimed.id) do
          {:ok, %Task{status: %{state: :completed}}} -> :ok
          _ -> {:error, :completion_not_stored}
        end
      else
        _ -> {:error, :claim_lost}
      end
    end)
  end

  @doc "`{:ok, result}` when `task` was rehydrated to completion, else `:error`."
  @spec result(Task.t()) :: {:ok, term()} | :error
  def result(%Task{metadata: metadata}) when is_map(metadata),
    do: Map.fetch(metadata, @result_metadata_key)

  def result(_other), do: :error

  defp put_result(%{metadata: metadata} = task, result),
    do: %{task | metadata: Map.put(metadata || %{}, @result_metadata_key, result)}

  defp safe_resume(resume_fun, task, frame) do
    resume_fun.(task, frame)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp pubsub do
    case Application.get_env(:ash_a2a, :cluster_pubsub) do
      {pubsub_name, topic} -> {pubsub_name, topic}
      pubsub_name when is_atom(pubsub_name) -> {pubsub_name, @default_topic}
      _other -> nil
    end
  end
end
