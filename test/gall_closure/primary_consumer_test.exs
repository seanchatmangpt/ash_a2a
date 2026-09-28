defmodule AshA2A.GallClosure.PrimaryConsumerTest do
  use ExUnit.Case, async: true
  alias AshA2A.GallClosure.PrimaryConsumer

  test "bounded admission",
    do: assert(match?({:ok, _}, PrimaryConsumer.admit(%{primary_consumer: "witness"})))

  test "typed refusal",
    do: assert(PrimaryConsumer.admit(%{}) == {:error, :missing_primary_consumer})
end
