defmodule AshA2A.Twin.Asset do
  @moduledoc """
  Asset twin: tracks operating windows and SLA countdown timers.

  `record_activity/2` opens an operating window and arms the SLA countdown
  (a real `gen_statem` event timer). If the window is not disarmed or
  refreshed before the countdown fires, the listener receives
  `{:sla_expired, name, meta}`. `disarm/1` closes the window cleanly.
  """

  alias AshA2A.Twin.Server

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {Server, :start_link, [:asset, Keyword.get(opts, :name, __MODULE__), opts]}
    }
  end

  @doc "Start an asset twin (must run under a DynamicSupervisor)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Server.start_link(:asset, name, opts)
  end

  @doc "Record activity: opens/refreshes the operating window and rearms the SLA timer."
  @spec record_activity(atom(), term()) :: :ok
  def record_activity(name, ref \\ :activity), do: Server.send_event(name, {:activity, ref})

  @doc "Disarm the SLA countdown (window closed cleanly)."
  @spec disarm(atom()) :: :ok
  def disarm(name), do: Server.send_event(name, :disarm)

  @doc "Status snapshot: sla_ms, ops count, armed?."
  @spec status(atom()) :: map()
  defdelegate status(name), to: Server

  @doc "Stop the twin."
  @spec stop(atom()) :: :ok
  defdelegate stop(name), to: Server
end
