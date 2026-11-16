# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.L18OptionalDepsTest do
  # Mutates application env (durable_server_provider), so not async.
  use ExUnit.Case, async: false

  alias AshA2A.Identity

  setup do
    previous = Application.fetch_env(:ash_a2a, :durable_server_provider)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore({:ok, value}), do: Application.put_env(:ash_a2a, :durable_server_provider, value)
  defp restore(:error), do: Application.delete_env(:ash_a2a, :durable_server_provider)

  test "DurableServer adapter returns a typed error when the provider module is absent" do
    Application.put_env(:ash_a2a, :durable_server_provider, AshA2A.L18.AbsentProvider)
    task_id = Identity.new(:task, "l18-task")

    refute AshA2A.Durability.DurableServer.available?()

    assert {:error, {:unsupported, :durable_server, :uncordon_child, 2}} =
             AshA2A.Durability.DurableServer.uncordon_task(:sup, task_id)
  end

  test "optional adapters never raise from available?/0 and degrade to typed errors" do
    assert is_boolean(AshA2A.Delivery.Oban.available?())
    assert is_boolean(AshA2A.Execution.FLAME.available?())
    assert is_boolean(AshA2A.TaskLifecycle.available?())

    unless AshA2A.TaskLifecycle.available?() do
      assert {:error, {:unsupported, :ash_state_machine}} =
               AshA2A.TaskLifecycle.possible_next_states(%{})
    end
  end

  test "default semantic generator degrades to a typed error when :req_llm is absent" do
    unless Code.ensure_loaded?(ReqLLM) do
      assert {:error, {:unsupported, :req_llm}} =
               AshA2A.Semantic.Compiler.default_generate_object(%{}, "p", [], [])

      assert {:error, {:unsupported, :req_llm}} =
               AshA2A.Planning.SemanticSynthesis.default_generate_object(%{}, "p", [], [])
    end
  end
end
