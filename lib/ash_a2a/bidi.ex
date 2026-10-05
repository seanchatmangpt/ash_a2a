# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Bidi do
  @moduledoc """
  Bidirectional streaming over the existing SSE transport.

  ## Design choice: per-stream input endpoint (HTTP POST), not SSE `data:` echo

  The A2A v1.x specification makes `message/stream` server→client only: the
  streaming doc states the SSE connection "remains open for the server to push
  events to the client", and SSE itself has no client→server payload channel
  (there is nothing in the frame format for a client to send anything but its
  HTTP request head). Bidirectional streaming is an explicit roadmap item
  (`vendors/a2a/docs/roadmap.md`, a2aproject/A2A#1995 — "continuous multi-turn
  messaging while agents are actively executing tasks"); until a bidirectional
  binding (the docs point at WebSockets, `custom-protocol-bindings.md`) exists
  upstream, the only spec-native client→server channel is HTTP POST.

  This module therefore adds the missing client→server direction as a
  **per-stream input endpoint** on the same transport: `POST
  <mount>/bidi/<task_id>/input` and `POST <mount>/bidi/<task_id>/close`,
  carried as JSON-RPC envelopes (method `bidi/input` / `bidi/close`) so
  request correlation and error reporting reuse the protocol's typed
  `google.rpc.ErrorInfo` vocabulary. The server→client direction is untouched
  (`AshA2A.A2ATransport.SSE` and the supervised pump are unchanged); the two
  directions compose into a bidirectional stream:

    * out: the skill's `{:stream, enum}` — chunked out through the existing
      supervised pump and event log, fan-out to every subscriber;
    * in: `AshA2A.Bidi.open/2` (with the handler context's `task_id`) opens a
      per-task input channel; `AshA2A.Bidi.Stream` turns it into a lazy input
      stream the running skill reads while its output enum is pulled. Inputs
      flow in only when the skill actually pulls — a consumer-driven pull, not
      a server-side buffer the client can fill faster than the skill reads.

  ## Lifecycle

    * **explicit close finalizes** — `POST /bidi/<task_id>/close` (or
      `AshA2A.Bidi.close/2`) closes the input channel; the skill's input
      stream yields `:eof`, the skill finalizes its output, the enum ends
      normally, `wrap_stream` reports `:complete`, and the task transitions to
      `:completed`. Idempotent: closing an already-closed/missing channel is
      still `:ok`.
    * **consumer death kills the skill's input**: the channel monitors the
      stream consumer (the supervised pump) at first pull; if the consumer is
      killed (client disconnect does not kill the pump — the transport's
      documented behavior is that a disconnect never halts the task — so this
      is the pump process itself), the channel closes, late input is refused,
      and the abandoned enumeration reports the task `:failed`.
    * **late input is a typed refusal**: input for a task with no live channel
      (never opened, already closed, task finished) is refused with a typed
      JSON-RPC error (see `AshA2A.Bidi.Plug`), never a silent drop.

  ## Example

      def handle_message(_message, ctx) do
        channel = AshA2A.Bidi.open(ctx.task_id)

        {:stream,
         AshA2A.Bidi.Stream.map_input(channel, fn input ->
           AshA2A.Protocol.Part.Text.new("echo: " <> AshA2A.Bidi.Stream.text(input))
         end)}
      end

  ## Supervision

  Channels live under a per-instance `DynamicSupervisor` and are addressed
  through a unique `Registry` keyed by task id. `{AshA2A.Bidi, name: name}`
  is a supervision-tree child (see `AshA2A.A2ATransport` for the same
  pattern); a host that skips it gets a self-healing lazy start on first use
  (`AshA2A.Bidi.ensure_started/0`), parented by the first caller.
  """

  use Supervisor

  alias AshA2A.Bidi.Channel

  @default_name __MODULE__

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @default_name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a bidi instance."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The default instance name."
  @spec default_name() :: atom()
  def default_name, do: @default_name

  @doc false
  def registry_name(name), do: Module.concat(name, Registry)
  @doc false
  def channel_sup_name(name), do: Module.concat(name, ChannelSup)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Registry, keys: :unique, name: registry_name(name)},
      {DynamicSupervisor, name: channel_sup_name(name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Ensures the named instance is running (idempotent, self-healing).

  Returns the running instance's name. Linked to the caller: a supervision
  tree host calls it once at boot; everyone else (skills, tests) hits the
  already-running case. If a previously lazily-started instance's parent has
  died, the next call restarts it under the new caller.
  """
  @spec ensure_started(atom()) :: atom()
  def ensure_started(name \\ @default_name) do
    case Process.whereis(name) do
      nil ->
        case Supervisor.start_link(__MODULE__, name: name, name: name) do
          {:ok, _pid} -> name
          {:error, {:already_started, _pid}} -> name
        end

      _running ->
        name
    end
  end

  @doc """
  Opens the input channel for a running task.

  Called by a skill inside `handle_message/2` with the handler context's
  `task_id`. Idempotent: reopening an already-open task's channel returns the
  existing channel pid. The channel is registered under the task id for the
  per-stream input endpoint and dies with the instance.
  """
  @spec open(String.t(), keyword()) :: pid()
  def open(task_id, opts \\ []) when is_binary(task_id) do
    name = Keyword.get(opts, :name, @default_name)
    ensure_started(name)

    case lookup(task_id, name) do
      {:ok, pid} ->
        pid

      :error ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            channel_sup_name(name),
            {Channel, task_id: task_id, registry: registry_name(name)}
            # The channel registers itself in `registry` during init and is
            # auto-deregistered by the Registry on death.
          )

        pid
    end
  end

  @doc """
  Delivers a client input (an `AshA2A.Protocol.Message` struct) to the task's
  channel. Returns `{:ok, :accepted}` or a typed refusal:

    * `{:error, :not_found}` — no live channel for the task id (never opened,
      already closed, or instance down);
    * `{:error, :closed}` — the channel existed but stopped accepting input
      (closed or its stream consumer died) before the delivery landed.

  """
  @spec deliver(String.t(), AshA2A.Protocol.Message.t(), keyword()) ::
          {:ok, :accepted} | {:error, :not_found | :closed}
  def deliver(task_id, %AshA2A.Protocol.Message{} = message, opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    case lookup(task_id, name) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:deliver, message})
        catch
          :exit, _ -> {:error, :closed}
        end

      :error ->
        {:error, :not_found}
    end
    |> tap(fn
      {:ok, :accepted} -> :telemetry.execute([:a2a, :bidi, :input], %{count: 1}, %{task_id: task_id})
      _ -> :ok
    end)
  end

  @doc """
  Explicitly closes the task's input channel. Idempotent: `:ok` for an open
  channel (the pending pull gets `:eof`, the skill finalizes), for an
  already-closed channel, and when no channel exists at all.
  """
  @spec close(String.t(), keyword()) :: :ok
  def close(task_id, opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    case lookup(task_id, name) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :close)
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  @doc "Look up the live channel pid for a task id, or `:error`."
  @spec lookup(String.t(), keyword()) :: {:ok, pid()} | :error
  def lookup(task_id, opts \\ []) when is_list(opts) do
    lookup(task_id, Keyword.get(opts, :name, @default_name))
  end

  @doc false
  @spec lookup(String.t(), atom()) :: {:ok, pid()} | :error
  def lookup(task_id, name) when is_atom(name) do
    case Registry.lookup(registry_name(name), task_id) do
      [{pid, _value} | _] -> {:ok, pid}
      [] -> :error
    end
  end
end

defmodule AshA2A.Bidi.Debug do
  def whereis, do: Process.whereis(AshA2A.Bidi)
end
