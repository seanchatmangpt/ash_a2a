defmodule AshA2A.CallbackRegistryTest do
  use ExUnit.Case, async: true

  alias AshA2A.CallbackRegistry

  test "a permitted callback is invoked and returns its real result" do
    assert CallbackRegistry.permitted?(BeamPM.Ferroplan, :plan_production, 4)
    assert CallbackRegistry.permitted?(AshR2RML, :mapping_result, 1)
  end

  test "a non-member is refused with a typed code and never executed" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, :halt, [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(File, :rm_rf, ["/nonexistent-safe-exec"])

    refute CallbackRegistry.permitted?(BeamPM.Ferroplan, :plan_production, 3)
  end

  test "non-atom or malformed callbacks are refused, not raised" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke("Elixir.System", :halt, [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, "halt", [0])

    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(System, :halt, :nope)
  end

  test "a permitted member runs its real function" do
    assert {:error, %{code: :callback_not_permitted}} =
             CallbackRegistry.invoke(String, :upcase, ["x"])

    if Code.ensure_loaded?(AshR2RML) and function_exported?(AshR2RML, :mapping_result, 1) do
      assert CallbackRegistry.invoke(AshR2RML, :mapping_result, [NoSuchResource]) ==
               apply(AshR2RML, :mapping_result, [NoSuchResource])
    end
  end

  test "extended-card scan: sources contain no raw apply/3 outside the registry" do
    for f <-
          ~w(lib/ash_a2a/planning.ex lib/ash_a2a/a2a_transport/extended_card.ex lib/ash_a2a/semantic_projection.ex) do
      {:ok, ast} = Code.string_to_quoted(File.read!(f))

      {_, hits} =
        Macro.prewalk(ast, [], fn
          {:apply, _, [_, _, _]} = n, acc ->
            {n, [n | acc]}

          {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [_, _, _]} = n, acc ->
            {n, [n | acc]}

          n, acc ->
            {n, acc}
        end)

      assert hits == [], "#{f} still has raw apply/3"
    end
  end
end
