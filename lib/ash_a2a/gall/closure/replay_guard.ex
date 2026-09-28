defmodule AshA2A.Gall.Closure.ReplayGuard do
  @moduledoc "Classifies exact replay without permitting a second consequence."

  def classify(previous, current) when is_map(previous) and is_map(current) do
    prev_command = AshA2A.Gall.Fields.get(previous, :command_id)
    curr_command = AshA2A.Gall.Fields.get(current, :command_id)
    prev_actuation = AshA2A.Gall.Fields.get(previous, :actuation_id)
    curr_actuation = AshA2A.Gall.Fields.get(current, :actuation_id)
    prev_key = AshA2A.Gall.Fields.get(previous, :idempotency_key)
    curr_key = AshA2A.Gall.Fields.get(current, :idempotency_key)

    cond do
      prev_key == curr_key and not is_nil(prev_key) and prev_actuation == curr_actuation ->
        {:ok, :exact_replay}

      prev_command == curr_command and prev_key != curr_key ->
        {:error, {:refused_gall, :replay_guard, :command_rebound_to_new_effect}}

      prev_actuation == curr_actuation and prev_key != curr_key ->
        {:error, {:refused_gall, :replay_guard, :actuation_identity_conflict}}

      true ->
        {:ok, :distinct}
    end
  end

  def classify(_, _), do: {:error, {:refused_gall, :replay_guard, :invalid_receipt}}
end
