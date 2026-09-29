defmodule AshA2A.ConsequenceKernel.ExactSubject do
  def bind(expected, observed) when expected == observed, do: :ok
  def bind(_, _), do: {:error, :prepared_record_identity_mismatch}
end
