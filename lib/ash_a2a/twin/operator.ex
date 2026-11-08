defmodule AshA2A.Twin.Operator do
  @moduledoc """
  Operator twin: tracks queue depth and attention budget.

  `enqueue/2` adds work; `attend/1` dequeues one item and consumes one unit
  of budget. When the budget reaches 0 the listener receives
  `{:budget_exhausted, name, meta}`. `recharge/1` restores budget; further
  `attend/1` calls with an empty budget are no-ops (fail-closed: no negative
  budget, no dequeue while exhausted).
  """

  alias AshA2A.Twin.Server

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {Server, :start_link, [:operator, Keyword.get(opts, :name, __MODULE__), opts]}
    }
  end

  @doc "Start an operator twin (must run under a DynamicSupervisor)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Server.start_link(:operator, name, opts)
  end

  @doc "Enqueue a work item."
  @spec enqueue(atom(), term()) :: :ok
  def enqueue(name, item), do: Server.send_event(name, {:enqueue, item})

  @doc "Attend to one queued item (consumes budget)."
  @spec attend(atom()) :: :ok
  def attend(name), do: Server.send_event(name, :attend)

  @doc "Recharge the attention budget (+5 units)."
  @spec recharge(atom()) :: :ok
  def recharge(name), do: Server.send_event(name, :recharge)

  @doc "Peek at the first n queued items."
  @spec peek(atom(), pos_integer()) :: [term()]
  def peek(name, n \\ 5), do: Server.call(name, {:peek, n})

  @doc "Status snapshot: queue depth, budget."
  @spec status(atom()) :: map()
  defdelegate status(name), to: Server

  @doc "Stop the twin."
  @spec stop(atom()) :: :ok
  defdelegate stop(name), to: Server
end
