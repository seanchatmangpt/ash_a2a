# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Bidi.Channel do
  @moduledoc """
  The per-task client→server input channel of `AshA2A.Bidi`.

  A channel is a small GenServer registered (unique) in the instance's
  `Registry` under the task id. State:

    * `queue` — inputs delivered before the skill pulls them (delivered
      ahead-of-consumption inputs are buffered, never dropped);
    * `waiter` — the one pending pull (the stream consumer pulls one input at
      a time; a second concurrent pull replaces the first);
    * `consumer` — monitored at first pull; its death closes the channel (the
      skill's stream can no longer be consumed, so input is meaningless);
    * `closed?` — explicitly closed; input after close is refused.

  The pull protocol is raw messages, not `GenServer.call`, so a pull that
  times out client-side can never leave a stale reply in the consumer's
  mailbox: each pull carries a unique reference, the channel replies to that
  reference, and a timed-out pull drains exactly its own late reply.
  """

  use GenServer, restart: :temporary

  @default_pull_timeout 30_000

  @typedoc "A pull result: an input, end-of-input, or the pull deadline passed."
  @type pulled :: {:ok, AshA2A.Protocol.Message.t()} | :eof | :timeout

  defstruct task_id: nil,
            queue: :queue.new(),
            size: 0,
            waiter: nil,
            waiter_mref: nil,
            consumer: nil,
            consumer_mref: nil,
            closed?: false

  # -- client API ----------------------------------------------------------------

  @doc "Starts (and registers) the channel for `task_id`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts))
  end

  @doc """
  Delivers `message` to the channel. `{:ok, :accepted}` when buffered (or
  handed straight to a waiting pull); `{:error, :closed}` once the channel is
  closed or its consumer is gone.
  """
  @spec deliver(GenServer.server(), term()) :: {:ok, :accepted} | {:error, :closed}
  def deliver(pid, message) do
    GenServer.call(pid, {:deliver, message})
  end

  @doc "Explicitly closes the channel. Idempotent. A pending pull gets `:eof`."
  @spec close(GenServer.server()) :: :ok
  def close(pid) do
    GenServer.call(pid, :close)
  end

  @doc """
  Pulls the next input, blocking up to `timeout` ms (default 30s).

  Returns `{:ok, input}` — delivered input; `:eof` — channel closed; or
  `:timeout` — deadline passed with no input. Called from the stream consumer
  (the supervised pump) while the skill's output enum is being pulled.
  """
  @spec pull(GenServer.server(), keyword() | non_neg_integer()) :: pulled()
  def pull(pid, timeout \\ @default_pull_timeout)

  def pull(pid, opts) when is_list(opts) do
    pull(pid, Keyword.get(opts, :timeout, @default_pull_timeout))
  end

  def pull(pid, timeout) when is_integer(timeout) and timeout > 0 do
    mref = Process.monitor(pid)
    req = make_ref()
    send(pid, {:bidi_pull, self(), req})

    receive do
      {:bidi_input, ^req, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        :eof
    after
      timeout ->
        Process.demonitor(mref, [:flush])

        # Drain this pull's own late reply so it cannot pollute the mailbox:
        # the unique `req` makes every stale message matchable and droppable.
        receive do
          {:bidi_input, ^req, _} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  # -- server --------------------------------------------------------------------

  @impl GenServer
  def init(%{task_id: task_id, registry: registry}) do
    {:ok, _} = Registry.register(registry, task_id, self())

    {:ok,
     %__MODULE__{
       task_id: task_id,
       queue: :queue.new(),
       waiter: nil,
       consumer: nil,
       closed?: false
     }}
  end

  @impl GenServer
  def handle_call({:deliver, message}, _from, state) do
    if state.closed? do
      {:reply, {:error, :closed}, state}
    else
      {:reply, {:ok, :accepted}, push(message, state)}
    end
  end

  def handle_call(:close, _from, state) do
    if state.closed? do
      {:reply, :ok, state}
    else
      # Reply before stopping so the closer never sees a shrunk call.
      {:reply, :ok, close_state(state)}
    end
  end

  # -- pull protocol ---------------------------------------------------------------

  @impl GenServer
  def handle_info({:bidi_pull, pid, req}, state) do
    # First pull adopts the consumer: monitor it so its death (the supervised
    # pump being killed or finishing) closes the channel.
    state =
      case state.consumer do
        nil ->
          %{state | consumer: pid, consumer_mref: Process.monitor(pid)}

        ^pid ->
          state

        _other ->
          # One consumer per channel; a second puller replaces the wait
          # target but not the monitored consumer.
          state
      end

    cond do
      state.closed? ->
        send(pid, {:bidi_input, req, :eof})
        {:noreply, state}

      state.size > 0 ->
        {input, state} = pop(state)
        send(pid, {:bidi_input, req, {:ok, input}})
        {:noreply, state}

      true ->
        # Nothing buffered: park this pull. Replacing a parked pull is
        # dropping the old waiter — the old consumer abandoned its pull
        # (timeout path drains its own late reply).
        if state.waiter do
          send(elem(state.waiter, 0), {:bidi_input, elem(state.waiter, 1), :eof})
        end

        {:noreply, %{state | waiter: {pid, req}, waiter_mref: Process.monitor(pid)}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    cond do
      state.waiter_mref == mref ->
        # The waiting puller died (its process, not a timeout — timeouts drain
        # their own reply). Unpark.
        {:noreply, %{state | waiter: nil, waiter_mref: nil}}

      state.consumer_mref == mref ->
        # The consumer is gone: the skill's output stream can no longer be
        # consumed, so the input channel is meaningless. Close and stop; the
        # Registry deregisters on death and late input becomes not_found.
        {:stop, :shutdown, %{state | closed?: true}}

      true ->
        {:noreply, state}
    end
  end

  # -- internals -------------------------------------------------------------------

  defp push(message, state) do
    case state.waiter do
      nil ->
        %{state | queue: :queue.in(message, state.queue), size: state.size + 1}

      {pid, req} ->
        send(pid, {:bidi_input, req, {:ok, message}})
        Process.demonitor(state.waiter_mref, [:flush])
        %{state | waiter: nil, waiter_mref: nil}
    end
  end

  defp pop(state) do
    {{:value, input}, queue} = :queue.out(state.queue)
    {input, %{state | queue: queue, size: state.size - 1}}
  end

  defp close_state(state) do
    if state.waiter do
      send(elem(state.waiter, 0), {:bidi_input, elem(state.waiter, 1), :eof})
    end

    %{state | closed?: true, waiter: nil, waiter_mref: nil}
  end
end
