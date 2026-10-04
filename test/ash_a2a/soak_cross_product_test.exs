defmodule AshA2A.SoakCrossProductTest do
  @moduledoc """
  Verifies the dynamic capability cross product space between `ash_a2a` and `ash_pplan`.
  Asserts that:
    1. Capabilities in `ash_a2a` and `ash_pplan` are discovered dynamically.
    2. The Cartesian space contains all expected capability interaction pairs.
    3. Soak evaluation runs cleanly with bounded memory and zero errors.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  test "dynamic cross product of ash_a2a and ash_pplan capabilities" do
    a2a_skills = Mix.Tasks.AshA2a.SoakTest.discover_a2a_skills()
    pplan_caps = Mix.Tasks.AshA2a.SoakTest.discover_pplan_capabilities()

    assert length(a2a_skills) > 0
    assert length(pplan_caps) > 0

    cross_product =
      for a <- a2a_skills, p <- pplan_caps do
        {a.id, p.id}
      end

    expected_size = length(a2a_skills) * length(pplan_caps)
    assert length(cross_product) == expected_size
    assert expected_size >= 100

    # Ensure all pplan capabilities parse under AshPPlan.Capability
    for {_a_id, p_id} <- cross_product do
      assert {:ok, _cap} = AshPPlan.Capability.parse(p_id)
    end
  end

  test "soak test runs sample cross-product evaluation batch cleanly" do
    # Run 10,000 evaluations across schedulers
    assert :ok = Mix.Tasks.AshA2a.SoakTest.run(["--agents", "10000", "--batch-size", "2500"])
  end
end
