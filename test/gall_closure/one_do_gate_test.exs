defmodule AshA2A.GallClosure.OneDoGateTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.OneDoGate
  test "bounded admission", do: assert(match?({:ok, _}, OneDoGate.admit(%{do_count: "witness"})))
  test "typed refusal", do: assert(OneDoGate.admit(%{}) == {:error, :invalid_do_count})
end
