defmodule AshA2A.GallClosure.ExactSubject do
  @moduledoc "Bounded GALL-029/030 guard for subject_id."
  def admit(%{subject_id: v}=s) when v not in [nil,false,""], do: {:ok, Map.put(s,:gall_guard,:exact_subject)}
  def admit(_), do: {:error,:missing_subject}
end
