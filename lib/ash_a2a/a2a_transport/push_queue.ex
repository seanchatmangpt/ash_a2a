# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.A2ATransport.PushQueue do
  @moduledoc """
  Pure per-key serial work queue used to keep webhook deliveries ordered.

  A2A requires push notifications for one task/config to reach the receiver
  in event order. Each `{task_id, config_id}` key owns a FIFO queue with at
  most one job running. `enqueue/5` starts a job immediately only when the key
  is idle; `down/3` (called when the running job's monitor fires) starts the
  next. A head job that exhausts its retries therefore delays -- but never
  reorders -- the events behind it.

  The structure is owned by `AshA2A.A2ATransport.TaskEvents`; `start_fun`
  receives a job and returns `{:ok, monitor_ref}` or `:error` (job dropped,
  proceed to the next).
  """

  defstruct keys: %{}, refs: %{}

  @type t :: %__MODULE__{keys: map(), refs: map()}

  @doc "An empty queue set."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Queues `job` under `key`; returns `{queues, :ok | :dropped}` (`:dropped` when `cap` is reached)."
  @spec enqueue(t(), term(), term(), (term() -> {:ok, reference()} | :error), pos_integer()) ::
          {t(), :ok | :dropped}
  def enqueue(%__MODULE__{} = pq, key, job, start_fun, cap) do
    case Map.get(pq.keys, key) do
      nil ->
        {run(pq, key, :queue.new(), job, start_fun), :ok}

      {q, ref} ->
        if :queue.len(q) >= cap,
          do: {pq, :dropped},
          else: {%{pq | keys: Map.put(pq.keys, key, {:queue.in(job, q), ref})}, :ok}
    end
  end

  @doc "Handles the monitor `ref` of a finished job: starts the key's next job, if any."
  @spec down(t(), reference(), (term() -> {:ok, reference()} | :error)) :: t()
  def down(%__MODULE__{} = pq, ref, start_fun) do
    case Map.pop(pq.refs, ref) do
      {nil, _} ->
        pq

      {key, refs} ->
        {q, _} = Map.fetch!(pq.keys, key)
        advance(%{pq | refs: refs}, key, q, start_fun)
    end
  end

  @doc "Number of keys with a running or queued job."
  @spec active_keys(t()) :: non_neg_integer()
  def active_keys(%__MODULE__{keys: keys}), do: map_size(keys)

  defp advance(pq, key, q, start_fun) do
    case :queue.out(q) do
      {:empty, _} -> %{pq | keys: Map.delete(pq.keys, key)}
      {{:value, job}, rest} -> run(pq, key, rest, job, start_fun)
    end
  end

  defp run(pq, key, q, job, start_fun) do
    case start_fun.(job) do
      {:ok, ref} ->
        %{pq | keys: Map.put(pq.keys, key, {q, ref}), refs: Map.put(pq.refs, ref, key)}

      :error ->
        advance(pq, key, q, start_fun)
    end
  end
end
