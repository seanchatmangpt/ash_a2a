defmodule AshA2A.ConsequenceKernel.PreparedEffectStore.Transition do
  @allowed %{prepared: [:claimed, :refused], claimed: [:applying, :released], applying: [:completed, :unknown_outcome], unknown_outcome: [:reconciled, :compensated]}
  def admit(from, to) when is_atom(from) and is_atom(to) do
    if to in Map.get(@allowed, from, []), do: :ok, else: {:error, :prepared_transition_refused}
  end
end
