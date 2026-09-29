defmodule AshA2A.C1W4B.UnknownObservationTest do
  use ExUnit.Case, async: true
  alias AshA2A.ConsequenceKernel.W4B.EntryPolicy
  test "unknown_observation", do: assert EntryPolicy.admit(:unknown, :observation) == {:error, :consequence_unclassified}
end
