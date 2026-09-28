defmodule AshA2A.GallClosure.ExactSubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.ExactSubject

  test "bounded admission",
    do: assert(match?({:ok, _}, ExactSubject.admit(%{subject_id: "witness"})))

  test "typed refusal", do: assert(ExactSubject.admit(%{}) == {:error, :missing_subject})
end
