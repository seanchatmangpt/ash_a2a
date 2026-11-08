defmodule AshA2A.Twin.Partner do
  @moduledoc """
  Partner twin: tracks shift state and the empirical response-latency
  distribution via `AshA2A.Twin.Hazard`.

  `dispatch/2` marks a dispatch outstanding (only while `:on_shift`);
  `response/2` feeds a latency observation into the hazard monitor. When an
  **unacknowledged** outstanding dispatch crosses the hazard threshold,
  `{:hazard_tripped, name, z, stats}` goes to the listener. `ack/1`
  acknowledges. Shift flips emit `{:shift_changed, name, shift}`.
  """

  alias AshA2A.Twin.Server

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {Server, :start_link, [:partner, Keyword.get(opts, :name, __MODULE__), opts]}
    }
  end

  @doc "Start a partner twin (must run under a DynamicSupervisor)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Server.start_link(:partner, name, opts)
  end

  @doc "Set shift state."
  @spec shift_on(atom()) :: :ok
  def shift_on(name), do: Server.send_event(name, :shift_on)

  @spec shift_off(atom()) :: :ok
  def shift_off(name), do: Server.send_event(name, :shift_off)

  @doc "Mark a dispatch outstanding."
  @spec dispatch(atom(), term()) :: :ok
  def dispatch(name, ref \\ :dispatch), do: Server.send_event(name, {:dispatch, ref})

  @doc "Feed a response latency (any unit; consistent units required)."
  @spec response(atom(), number()) :: :ok
  def response(name, latency), do: Server.send_event(name, {:response, latency})

  @doc "Acknowledge the outstanding dispatch (suppresses trips until next dispatch)."
  @spec ack(atom()) :: :ok
  def ack(name), do: Server.send_event(name, :ack)

  @doc "Status snapshot: shift, acked?, threshold, hazard window size."
  @spec status(atom()) :: map()
  defdelegate status(name), to: Server

  @doc "Stop the twin."
  @spec stop(atom()) :: :ok
  defdelegate stop(name), to: Server
end
