defmodule AshA2A.GallClosure.SimulationConsumerTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.SimulationConsumer
 test "bounded admission", do: assert match?({:ok,_}, SimulationConsumer.admit(%{simulation_consumer: "witness"}))
 test "typed refusal", do: assert SimulationConsumer.admit(%{}) == {:error,:missing_simulation_consumer}
end
