defmodule AshA2A.SagaControl do
  @moduledoc """
  Powerless cancellation/timeout/compensation state machine.

  This module selects and constructs recovery intent. It never dispatches an
  Ash action and never calls CommandBus; consequential compensation must be
  submitted as a new admitted command through AshA2A.CommandBus.
  """

  @states [:pending, :running, :cancel_requested, :timed_out, :compensation_required, :settled]
  @terminal [:settled]
  @authority_ceiling :construct

  @type state :: atom()
  @type saga :: %{
          required(:subject) => String.t(),
          required(:epoch) => non_neg_integer(),
          required(:state) => state(),
          required(:deadline_ms) => integer(),
          required(:steps) => [map()],
          required(:receipts) => [map()]
        }

  @spec new(String.t(), non_neg_integer(), integer()) :: saga()
  def new(subject, epoch, deadline_ms)
      when is_binary(subject) and byte_size(subject) > 0 and is_integer(epoch) and epoch >= 0 and
             is_integer(deadline_ms) do
    %{subject: subject, epoch: epoch, state: :pending, deadline_ms: deadline_ms, steps: [], receipts: []}
  end

  @spec start(saga(), integer()) :: {:ok, saga(), map()} | {:error, atom()}
  def start(%{state: :pending} = saga, now_ms), do: transition(saga, :running, :start, now_ms)
  def start(_saga, _now_ms), do: {:error, :invalid_state}

  @spec cancel(saga(), non_neg_integer(), integer()) :: {:ok, saga(), map()} | {:error, atom()}
  def cancel(%{epoch: epoch, state: state} = saga, epoch, now_ms)
      when state in [:pending, :running] do
    transition(saga, :cancel_requested, :cancel, now_ms)
  end
  def cancel(%{epoch: actual}, requested, _now_ms) when actual != requested, do: {:error, :stale_epoch}
  def cancel(_saga, _epoch, _now_ms), do: {:error, :already_terminal_or_recovering}

  @spec tick(saga(), non_neg_integer(), integer()) :: {:ok, saga(), map()} | {:noop, saga()} | {:error, atom()}
  def tick(%{epoch: epoch} = saga, requested_epoch, _now_ms) when epoch != requested_epoch,
    do: {:error, :stale_epoch}
  def tick(%{state: :running, deadline_ms: deadline} = saga, epoch, now_ms) when now_ms >= deadline,
    do: transition(saga, :timed_out, :timeout, now_ms)
  def tick(saga, _epoch, _now_ms), do: {:noop, saga}

  @spec require_compensation(saga(), non_neg_integer(), [map()], integer()) ::
          {:ok, saga(), map()} | {:error, atom()}
  def require_compensation(%{epoch: epoch, state: state} = saga, epoch, completed_steps, now_ms)
      when state in [:cancel_requested, :timed_out] and is_list(completed_steps) do
    compensation =
      completed_steps
      |> Enum.reverse()
      |> Enum.filter(&Map.get(&1, :compensatable?, false))
      |> Enum.map(fn step ->
        %{step_id: Map.fetch!(step, :id), command: Map.fetch!(step, :compensation_command)}
      end)

    saga = %{saga | steps: compensation}
    transition(saga, :compensation_required, :construct_compensation, now_ms)
  end
  def require_compensation(%{epoch: actual}, requested, _steps, _now_ms) when actual != requested,
    do: {:error, :stale_epoch}
  def require_compensation(_saga, _epoch, _steps, _now_ms), do: {:error, :compensation_not_admitted}

  @doc "Returns powerless command intents; callers must route them through CommandBus."
  @spec compensation_intents(saga()) :: {:ok, [map()]} | {:error, atom()}
  def compensation_intents(%{state: :compensation_required, steps: steps, subject: subject, epoch: epoch}) do
    {:ok,
     Enum.map(steps, fn step ->
       %{subject: subject, epoch: epoch, authority: @authority_ceiling, do?: false, command: step.command}
     end)}
  end
  def compensation_intents(_), do: {:error, :compensation_not_required}

  @spec settle(saga(), non_neg_integer(), [map()], integer()) :: {:ok, saga(), map()} | {:error, atom()}
  def settle(%{epoch: epoch, state: :compensation_required, steps: steps} = saga, epoch, receipts, now_ms)
      when is_list(receipts) do
    expected = MapSet.new(Enum.map(steps, & &1.step_id))
    observed = MapSet.new(Enum.map(receipts, &Map.get(&1, :step_id)))

    if expected == observed and Enum.all?(receipts, &(Map.get(&1, :standing) in [:known_replay, :alive])) do
      saga = %{saga | receipts: receipts}
      transition(saga, :settled, :settle, now_ms)
    else
      {:error, :receipt_closure_incomplete}
    end
  end
  def settle(%{epoch: actual}, requested, _receipts, _now_ms) when actual != requested,
    do: {:error, :stale_epoch}
  def settle(_saga, _epoch, _receipts, _now_ms), do: {:error, :settlement_not_admitted}

  @spec replay([map()]) :: {:ok, map()} | {:error, atom()}
  def replay(events) when is_list(events) do
    with true <- events != [],
         [first | _] <- events,
         subject when is_binary(subject) <- Map.get(first, :subject),
         epoch when is_integer(epoch) <- Map.get(first, :epoch),
         true <- Enum.all?(events, &(Map.get(&1, :subject) == subject and Map.get(&1, :epoch) == epoch)),
         true <- deterministic_chain?(events) do
      {:ok, %{subject: subject, epoch: epoch, state: Map.get(List.last(events), :to), digest: digest(events)}}
    else
      _ -> {:error, :invalid_replay}
    end
  end

  @spec ontology_contract(String.t()) :: :ok | {:error, {:ontology_contract_missing, String.t()}}
  def ontology_contract(path \\ Path.join(:code.priv_dir(:ash_a2a), "ontology/saga_control.ttl")) do
    ttl = File.read!(path)
    required = ["ce:Planner", "ce:Policy", "ce:Role", "ce:Agent", "ce:Authority", "ce:DO",
                "ce:Standing", "ce:Construct", "ce:CommandBus", "ce:staleEpochRefusal"]

    case Enum.find(required, &(not String.contains?(ttl, &1))) do
      nil -> :ok
      token -> {:error, {:ontology_contract_missing, token}}
    end
  end

  defp transition(saga, to, event, now_ms) when to in @states do
    receipt = %{
      id: digest({saga.subject, saga.epoch, saga.state, to, event, now_ms}),
      subject: saga.subject,
      epoch: saga.epoch,
      from: saga.state,
      to: to,
      event: event,
      observed_at_ms: now_ms,
      authority: @authority_ceiling,
      do?: false
    }
    {:ok, %{saga | state: to}, receipt}
  end

  defp deterministic_chain?([_]), do: true
  defp deterministic_chain?([a, b | rest]),
    do: Map.get(a, :to) == Map.get(b, :from) and deterministic_chain?([b | rest])

  defp digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16(case: :lower)
end
