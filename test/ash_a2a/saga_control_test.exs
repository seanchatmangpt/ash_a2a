defmodule AshA2A.SagaControlTest do
  use ExUnit.Case, async: true

  alias AshA2A.SagaControl

  defp running(deadline \\ 1_000) do
    {:ok, saga, _} = SagaControl.new("saga-1", 3, deadline) |> SagaControl.start(0)
    saga
  end

  test "stale epoch is refused on every epoch-bound transition" do
    saga = running()
    assert SagaControl.cancel(saga, 2, 10) == {:error, :stale_epoch}
    assert SagaControl.tick(saga, 4, 10) == {:error, :stale_epoch}
    assert SagaControl.require_compensation(saga, 2, [], 10) == {:error, :stale_epoch}
    assert SagaControl.settle(saga, 2, [], 10) == {:error, :stale_epoch}
  end

  test "deadline times a running saga out; before deadline is a noop" do
    saga = running(100)
    assert {:noop, ^saga} = SagaControl.tick(saga, 3, 99)

    assert {:ok, %{state: :timed_out}, %{event: :timeout, do?: false}} =
             SagaControl.tick(saga, 3, 100)
  end

  test "compensation reverses completed steps, keeps only compensatable ones, and is powerless" do
    {:ok, saga, _} = SagaControl.cancel(running(), 3, 5)

    steps = [
      %{id: "a", compensatable?: true, compensation_command: :undo_a},
      %{id: "b", compensatable?: false, compensation_command: :undo_b},
      %{id: "c", compensatable?: true, compensation_command: :undo_c}
    ]

    {:ok, saga, receipt} = SagaControl.require_compensation(saga, 3, steps, 6)
    assert receipt.authority == :construct
    {:ok, intents} = SagaControl.compensation_intents(saga)
    assert Enum.map(intents, & &1.command) == [:undo_c, :undo_a]
    assert Enum.all?(intents, &(&1.do? == false and &1.authority == :construct))
  end

  test "settle requires receipt closure over exactly the compensation steps" do
    {:ok, saga, _} = SagaControl.cancel(running(), 3, 5)
    steps = [%{id: "a", compensatable?: true, compensation_command: :undo_a}]
    {:ok, saga, _} = SagaControl.require_compensation(saga, 3, steps, 6)

    assert SagaControl.settle(saga, 3, [], 7) == {:error, :receipt_closure_incomplete}

    assert SagaControl.settle(saga, 3, [%{step_id: "a", standing: :refuted}], 7) ==
             {:error, :receipt_closure_incomplete}

    {:ok, settled, _} = SagaControl.settle(saga, 3, [%{step_id: "a", standing: :alive}], 7)
    assert SagaControl.terminal?(settled)
    refute SagaControl.terminal?(saga)
  end

  test "replay digest is deterministic and rejects broken chains" do
    saga = SagaControl.new("saga-1", 3, 1_000)
    {:ok, s1, r1} = SagaControl.start(saga, 0)
    {:ok, _s2, r2} = SagaControl.cancel(s1, 3, 5)

    assert {:ok, a} = SagaControl.replay([r1, r2])
    assert {:ok, ^a} = SagaControl.replay([r1, r2])
    assert a.state == :cancel_requested
    assert SagaControl.replay([r2, r1]) == {:error, :invalid_replay}
    assert SagaControl.replay([]) == {:error, :invalid_replay}
  end

  test "ontology contract is satisfied by the shipped TTL and typed when missing" do
    assert SagaControl.ontology_contract() == :ok

    assert SagaControl.ontology_contract("/nonexistent/saga.ttl") ==
             {:error, {:ontology_contract_missing, "/nonexistent/saga.ttl"}}
  end
end
