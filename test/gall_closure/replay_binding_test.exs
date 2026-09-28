defmodule AshA2A.GallClosure.ReplayBindingTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.ReplayBinding
 test "bounded admission", do: assert match?({:ok,_}, ReplayBinding.admit(%{replay_id: "witness"}))
 test "typed refusal", do: assert ReplayBinding.admit(%{}) == {:error,:missing_replay}
end
