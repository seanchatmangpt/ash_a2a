defmodule AshA2A.Test.Support.KillSwitchDemo.Worker do
  @moduledoc """
  Real demo worker for `AshA2A.KillSwitch`'s isolation proof
  (`test/ash_a2a/kill_switch_test.exs`). Each worker is a real `GenServer`
  process belonging to one `class`; before performing each unit of
  harmless, self-contained "work" (incrementing its own in-process
  counter), it real-checks `AshA2A.KillSwitch.tripped?/1` for its class and
  refuses new work while tripped -- this observes a real behavior change in
  a real process, not a documentation claim about one.

  Deliberately does not know or care about `AshA2A.CommandBus`,
  `AshA2A.Command`, or any dispatch path -- this pool exists only to prove
  `AshA2A.KillSwitch` in isolation, per that module's own moduledoc scope.
  """

  use GenServer

  alias AshA2A.KillSwitch

  defstruct [:class, completed: 0, refused: 0]

  @type t :: %__MODULE__{
          class: KillSwitch.class(),
          completed: non_neg_integer(),
          refused: non_neg_integer()
        }

  @spec start_link(KillSwitch.class()) :: GenServer.on_start()
  def start_link(class), do: GenServer.start_link(__MODULE__, class)

  @impl true
  def init(class), do: {:ok, %__MODULE__{class: class}}

  @doc """
  Ask this worker to perform one unit of work. Returns `{:ok, completed}`
  when the worker's class was not tripped at the moment of the check, or
  `{:refused, reason}` (the real reason `AshA2A.KillSwitch.trip/3` recorded)
  when it was.
  """
  @spec perform_work(pid()) :: {:ok, non_neg_integer()} | {:refused, KillSwitch.reason()}
  def perform_work(pid), do: GenServer.call(pid, :perform_work)

  @spec status(pid()) :: t()
  def status(pid), do: GenServer.call(pid, :status)

  @impl true
  def handle_call(:perform_work, _from, %__MODULE__{class: class} = state) do
    case KillSwitch.tripped?(class) do
      {true, reason} ->
        {:reply, {:refused, reason}, %{state | refused: state.refused + 1}}

      false ->
        state = %{state | completed: state.completed + 1}
        {:reply, {:ok, state.completed}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}
end
