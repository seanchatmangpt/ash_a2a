defmodule AshA2A.Twin.HazardTest do
  use ExUnit.Case, async: true

  alias AshA2A.Twin.Hazard

  test "new/1 rejects non-positive and non-integer capacity; new/0 uses default" do
    assert Hazard.new().capacity == Hazard.default_capacity()
    for bad <- [0, -3, 1.5, nil, "8"], do: assert_raise(ArgumentError, fn -> Hazard.new(bad) end)
  end

  test "observe error path returns the typed error and does not push" do
    h = Enum.reduce([10, 10, 10], Hazard.new(8), &Hazard.push(&2, &1))
    assert {:error, :insufficient_dispersion} = Hazard.observe(h, 11)
    assert Hazard.window(h) == [10, 10, 10]
  end

  test "non-number observation is a typed error" do
    h = Hazard.new(4)
    assert {:error, :invalid_observation} = Hazard.observe(h, "fast")
    assert {:error, :invalid_observation} = Hazard.observe(h, nil)
    assert {:error, :invalid_observation} = Hazard.zscore(:x, [1, 2, 3])
    assert {:error, :invalid_observation} = Hazard.zscore(5, :window)
  end

  test "median of empty window raises ArgumentError; mad of empty is 0.0" do
    assert_raise ArgumentError, fn -> Hazard.median([]) end
    assert Hazard.mad([]) == 0.0
  end

  test "zero_dispersion_spike: slow spike on established flat window; others none" do
    assert {:spike, %{z: :infinity, median: 10.0, trip?: true}} =
             Hazard.zero_dispersion_spike([10, 10, 10, 10], 1_000)

    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], 10)
    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], 5)
    assert :none = Hazard.zero_dispersion_spike([10, 10], 1_000)
    assert :none = Hazard.zero_dispersion_spike([], 1_000)
    assert :none = Hazard.zero_dispersion_spike([10, 10, 10], nil)
    # dispersed window is not zero-dispersion
    assert :none = Hazard.zero_dispersion_spike([1, 5, 9, 12], 1_000)
  end
end
