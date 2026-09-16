defmodule AshA2A.Semantic.BoundsTest do
  @moduledoc """
  RFC-SA2A-001 S34 (fan-out / depth / parallelism ceilings), S35 (resource
  envelope, fail closed), S73 (no blank check: a subtask may not manufacture
  authority or budget for itself; delegation may only narrow).

  Real struct, real state assertions. No mocks -- there is nothing here to
  mock: `AshA2A.Semantic.Bounds` is a pure value type and every assertion is
  on its real returned state or its real typed refusal.
  """
  use ExUnit.Case, async: true

  doctest AshA2A.Semantic.Bounds

  alias AshA2A.Semantic.Bounds

  defp envelope(opts \\ []) do
    {:ok, bounds} =
      Bounds.new(
        Keyword.merge(
          [
            fan_out: 4,
            depth: 2,
            parallelism: 3,
            resources: %{tokens: 1000, wall_ms: 5_000},
            capabilities: ["Res.read", "Res.write"]
          ],
          opts
        )
      )

    bounds
  end

  describe "S35 -- construction fails closed" do
    test "every ceiling is required; an omitted one is an error, not unlimited" do
      assert {:error, %{code: :bounds_ceiling_missing, detail: :fan_out}} =
               Bounds.new(depth: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_missing, detail: :depth}} =
               Bounds.new(fan_out: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_missing, detail: :parallelism}} =
               Bounds.new(fan_out: 1, depth: 1)
    end

    test ":infinity and negatives are refused, not coerced" do
      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :fan_out}}} =
               Bounds.new(fan_out: :infinity, depth: 1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :depth}}} =
               Bounds.new(fan_out: 1, depth: -1, parallelism: 1)

      assert {:error, %{code: :bounds_ceiling_invalid, detail: %{field: :parallelism}}} =
               Bounds.new(fan_out: 1, depth: 1, parallelism: 0)
    end

    test "a constructed envelope carries no authority and cannot be given any" do
      bounds = envelope()
      assert bounds.authority == :none
      assert Bounds.fence(bounds) == :ok

      # Even if a struct is forced into an authority-bearing shape, the fence
      # refuses it and delegation from it is impossible.
      forged = %{bounds | authority: :granted}
      assert {:error, %{code: :bounds_authority_ceiling_violated}} = Bounds.fence(forged)
      assert {:error, %{code: :bounds_authority_ceiling_violated}} = Bounds.delegate(forged, [])
    end
  end

  describe "S34 -- fan-out, depth, and parallelism ceilings" do
    test "at the ceiling is admitted; one over is refused with the real numbers" do
      bounds = envelope()

      assert Bounds.admit_fan_out(bounds, 4) == :ok

      assert Bounds.admit_fan_out(bounds, 5) ==
               {:error, %{code: :bounds_fan_out_exceeded, detail: %{ceiling: 4, requested: 5}}}

      assert Bounds.admit_depth(bounds, 2) == :ok

      assert Bounds.admit_depth(bounds, 3) ==
               {:error, %{code: :bounds_depth_exceeded, detail: %{ceiling: 2, requested: 3}}}

      assert Bounds.admit_parallelism(bounds, 3) == :ok

      assert Bounds.admit_parallelism(bounds, 4) ==
               {:error,
                %{code: :bounds_parallelism_exceeded, detail: %{ceiling: 3, requested: 4}}}
    end

    test "a zero ceiling admits nothing at all" do
      bounds = envelope(fan_out: 0)
      assert Bounds.admit_fan_out(bounds, 0) == :ok
      assert {:error, %{code: :bounds_fan_out_exceeded}} = Bounds.admit_fan_out(bounds, 1)
    end

    test "a capability outside the delegated set is refused" do
      bounds = envelope()
      assert Bounds.admit_capability(bounds, "Res.read") == :ok

      assert Bounds.admit_capability(bounds, "Res.destroy") ==
               {:error, %{code: :bounds_capability_not_delegated, detail: "Res.destroy"}}
    end
  end

  describe "S35 -- the resource envelope fails closed on exhaustion" do
    test "spending reduces real remaining state and exhaustion refuses" do
      bounds = envelope()

      assert {:ok, after_first} = Bounds.consume(bounds, :tokens, 600)
      assert after_first.resources[:tokens] == 400

      assert {:ok, after_second} = Bounds.consume(after_first, :tokens, 400)
      assert after_second.resources[:tokens] == 0

      assert Bounds.consume(after_second, :tokens, 1) ==
               {:error,
                %{
                  code: :bounds_resource_exhausted,
                  detail: %{key: :tokens, remaining: 0, requested: 1}
                }}

      # Refusal is not a clamp: the envelope is unchanged and the other
      # budget is untouched.
      assert after_second.resources[:wall_ms] == 5_000
    end

    test "an unknown resource key is a refusal, never an implicitly unlimited budget" do
      assert Bounds.consume(envelope(), :gpu_seconds, 1) ==
               {:error, %{code: :bounds_resource_unknown, detail: :gpu_seconds}}
    end

    test "a negative spend (a covert refund) is refused" do
      assert {:error, %{code: :bounds_resource_amount_invalid}} =
               Bounds.consume(envelope(), :tokens, -100)
    end
  end

  describe "S73 -- no blank check: delegation may only narrow" do
    test "a subtask requesting MORE fan-out than delegated is refused, naming the field" do
      parent = envelope(fan_out: 2)

      assert Bounds.delegate(parent, fan_out: 3) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :fan_out, parent: 2, requested: 3}
                }}
    end

    test "a subtask requesting MORE budget than delegated is refused, naming the resource" do
      parent = envelope(resources: %{tokens: 100})

      assert Bounds.delegate(parent, resources: %{tokens: 101}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 100, requested: 101}
                }}
    end

    test "a subtask requesting a capability it was never delegated is refused" do
      parent = envelope(capabilities: ["Res.read"])

      assert {:error,
              %{
                code: :bounds_delegation_not_narrowing,
                detail: %{field: :capabilities, requested: ["Res.destroy"]}
              }} = Bounds.delegate(parent, capabilities: ["Res.read", "Res.destroy"])
    end

    test "a subtask cannot request a resource key its parent does not hold at all" do
      parent = envelope(resources: %{tokens: 100})

      assert Bounds.delegate(parent, resources: %{gpu_seconds: 1}) ==
               {:error, %{code: :bounds_resource_unknown, detail: :gpu_seconds}}
    end

    test "a subtask cannot ask for authority at all, even :none" do
      assert {:error, %{code: :bounds_authority_not_delegable, detail: :none}} =
               Bounds.delegate(envelope(), authority: :none)

      assert {:error, %{code: :bounds_authority_not_delegable, detail: :granted}} =
               Bounds.delegate(envelope(), authority: :granted)
    end

    test "delegation strictly consumes a level of depth and bottoms out" do
      parent = envelope(depth: 1)

      assert {:ok, %{child: child}} = Bounds.delegate(parent, [])
      assert child.depth == 0

      # ... and a depth-0 envelope cannot delegate further.
      assert Bounds.delegate(child, []) ==
               {:error, %{code: :bounds_depth_exhausted, detail: 0}}
    end

    test "a subtask cannot request depth equal to its parent's (that would be an infinite ladder)" do
      parent = envelope(depth: 2)

      assert Bounds.delegate(parent, depth: 2) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :depth, parent: 1, requested: 2}
                }}
    end

    test "a legal narrowing delegation produces a real child AND debits the real parent" do
      parent = envelope(fan_out: 4, depth: 2, parallelism: 3, resources: %{tokens: 1000})

      assert {:ok, %{child: child, parent: debited}} =
               Bounds.delegate(parent,
                 fan_out: 2,
                 parallelism: 1,
                 resources: %{tokens: 300},
                 capabilities: ["Res.read"]
               )

      assert child.fan_out == 2
      assert child.depth == 1
      assert child.parallelism == 1
      assert child.resources == %{tokens: 300}
      assert MapSet.to_list(child.capabilities) == ["Res.read"]
      assert child.authority == :none

      # The budget was MOVED, not copied: the parent really lost it.
      assert debited.resources == %{tokens: 700}
      assert debited.fan_out == parent.fan_out
    end

    test "budget cannot be manufactured by delegating twice: the second delegation sees the debited parent",
         %{} do
      parent = envelope(resources: %{tokens: 100}, depth: 2)

      assert {:ok, %{child: first, parent: after_first}} =
               Bounds.delegate(parent, resources: %{tokens: 60})

      assert first.resources == %{tokens: 60}
      assert after_first.resources == %{tokens: 40}

      # A second subtask asking for 60 again is refused -- there are only 40
      # left. Without the debit this would have handed out 120 of a 100 budget.
      assert Bounds.delegate(after_first, resources: %{tokens: 60}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 40, requested: 60}
                }}

      assert {:ok, %{child: second, parent: after_second}} =
               Bounds.delegate(after_first, resources: %{tokens: 40})

      assert second.resources == %{tokens: 40}
      assert after_second.resources == %{tokens: 0}

      # Conservation: nothing was created.
      assert first.resources[:tokens] + second.resources[:tokens] +
               after_second.resources[:tokens] == 100
    end

    test "a grandchild cannot exceed what its parent was itself delegated" do
      root = envelope(fan_out: 8, depth: 3, parallelism: 4, resources: %{tokens: 1000})

      assert {:ok, %{child: child}} =
               Bounds.delegate(root, fan_out: 3, resources: %{tokens: 100})

      assert Bounds.delegate(child, fan_out: 4) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: :fan_out, parent: 3, requested: 4}
                }}

      assert Bounds.delegate(child, resources: %{tokens: 150}) ==
               {:error,
                %{
                  code: :bounds_delegation_not_narrowing,
                  detail: %{field: {:resources, :tokens}, parent: 100, requested: 150}
                }}

      assert {:ok, %{child: grandchild}} =
               Bounds.delegate(child, fan_out: 1, resources: %{tokens: 10})

      assert grandchild.depth == 1
      assert grandchild.authority == :none
    end
  end

  describe "Bounds is an envelope, never a grant (S28)" do
    test "holding budget for a capability is not authority for it" do
      bounds = envelope(capabilities: ["AshA2A.Test.Fixture.AuthorityProbe.actuate"])

      # The envelope does not forbid it ...
      assert Bounds.admit_capability(bounds, "AshA2A.Test.Fixture.AuthorityProbe.actuate") == :ok

      # ... and the envelope still carries no authority whatsoever. There is
      # no function on this module that returns an AshA2A.Authority, by
      # construction.
      assert bounds.authority == :none

      refute :erlang.function_exported(Bounds, :authority, 1)

      refute Enum.any?(Bounds.__info__(:functions), fn {name, _arity} ->
               name in [:grant, :issue, :authorize, :elevate]
             end)
    end
  end
end
