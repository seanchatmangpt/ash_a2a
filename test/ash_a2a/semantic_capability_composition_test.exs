defmodule AshA2A.Semantic.CapabilityCompositionTest do
  @moduledoc """
  RFC-SA2A-001 S48: capabilities compose when `Effects(c1)` entails
  `Preconditions(c2)`, and authority requirements remain INDEPENDENT --
  composing two capabilities MUST NOT raise either participant's authority
  ceiling.

  All state-based: real STRIPS transforms over real fact sets, real returned
  structs, real refusal tuples.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{CapabilityComposition, CapabilityProfile, Composition}

  # `advance` mirrors the real `test/support/hddl/freedom_gym_meeting/domain.hddl`
  # action: precondition `(current-phase ?from)`, effect
  # `(and (not (current-phase ?from)) (current-phase ?to))`.
  defp advance(from, to, opts \\ []) do
    %CapabilityProfile{
      capability_id: Keyword.get(opts, :id, "advance:#{from}->#{to}"),
      consequence: Keyword.get(opts, :consequence, :change),
      preconditions: [{:"current-phase", [from]}],
      add_effects: [{:"current-phase", [to]}],
      delete_effects: [{:"current-phase", [from]}],
      authority_requirement: Keyword.get(opts, :authority_requirement, %{})
    }
  end

  describe "S48 -- Effects(c1) entails Preconditions(c2)" do
    test "composes when c1's effects alone establish c2's preconditions" do
      c1 = advance(:open, :"trust-god")
      c2 = advance(:"trust-god", :"clean-house")

      assert {:ok, %Composition{} = composition} = CapabilityComposition.compose(c1, c2)

      assert composition.left == "advance:open->trust-god"
      assert composition.right == "advance:trust-god->clean-house"
      assert composition.resulting_state == [{"current-phase", ["clean-house"]}]
      assert composition.standing == :candidate
      assert composition.authority == :none
      assert composition.composition_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "refuses when c1's effects do not establish c2's preconditions, naming the unmet facts" do
      c1 = advance(:open, :"trust-god")
      c2 = advance(:fellowship, :close)

      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"current-phase", ["fellowship"]}]
      assert detail.resulting_state == [{"current-phase", ["trust-god"]}]
      assert detail.left == "advance:open->trust-god"
      assert detail.right == "advance:fellowship->close"
    end

    test "delete effects are honored after adds -- a self-deleting effect does not satisfy c2" do
      # c1 adds `(ready)` and then deletes it. Its net effect establishes
      # nothing, so a c2 requiring `(ready)` must NOT compose.
      c1 = %CapabilityProfile{
        capability_id: "adds-then-deletes",
        preconditions: [],
        add_effects: [{:ready, []}],
        delete_effects: [{:ready, []}]
      }

      c2 = %CapabilityProfile{
        capability_id: "needs-ready",
        preconditions: [{:ready, []}],
        add_effects: [{:done, []}],
        delete_effects: []
      }

      assert CapabilityComposition.apply_effects([], c1) == []

      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"ready", []}]
    end

    test "the default is the STRICT reading: an ambient prior state does not help unless supplied" do
      c1 = %CapabilityProfile{
        capability_id: "c1",
        add_effects: [{:a, []}],
        preconditions: [],
        delete_effects: []
      }

      c2 = %CapabilityProfile{
        capability_id: "c2",
        preconditions: [{:a, []}, {:b, []}],
        add_effects: [{:c, []}],
        delete_effects: []
      }

      # Strict: c1 alone does not establish `(b)`.
      assert {:error, %{code: :composition_preconditions_unmet, detail: detail}} =
               CapabilityComposition.compose(c1, c2)

      assert detail.unmet == [{"b", []}]

      # Frame-aware, explicitly requested at the call site:
      assert {:ok, composition} =
               CapabilityComposition.compose(c1, c2, initial_state: [{:b, []}])

      assert composition.resulting_state == [{"a", []}, {"b", []}, {"c", []}]
    end

    test "atom-shaped and string-shaped facts are the same fact" do
      dsl_side = %CapabilityProfile{
        capability_id: "dsl",
        preconditions: [],
        add_effects: [{:at, [:room_a]}],
        delete_effects: []
      }

      wire_side = %CapabilityProfile{
        capability_id: "wire",
        preconditions: [{"at", ["room_a"]}],
        add_effects: [{"arrived", []}],
        delete_effects: []
      }

      assert {:ok, composition} = CapabilityComposition.compose(dsl_side, wire_side)
      assert composition.resulting_state == [{"arrived", []}, {"at", ["room_a"]}]
    end

    test "entails?/2 and unmet/2 agree with each other" do
      state = [{:a, []}, {:b, [:x]}]

      assert CapabilityComposition.entails?(state, [{:a, []}])
      assert CapabilityComposition.entails?(state, [{"b", ["x"]}])
      refute CapabilityComposition.entails?(state, [{:c, []}])

      assert CapabilityComposition.unmet(state, [{:a, []}, {:c, []}]) == [{"c", []}]
      assert CapabilityComposition.unmet(state, [{:a, []}]) == []
    end

    test "self-composition is refused" do
      c = advance(:open, :close, id: "same")

      assert {:error, %{code: :composition_self_composition, detail: "same"}} =
               CapabilityComposition.compose(c, c)
    end
  end

  describe "S48 -- composing MUST NOT raise either participant's authority ceiling" do
    test "each participant's requirement is preserved verbatim, per participant" do
      low = advance(:open, :mid, id: "low", authority_requirement: %{mode: :none})

      high =
        advance(:mid, :close,
          id: "high",
          authority_requirement: %{mode: :required, scope: "admin", expires_in_s: 60}
        )

      assert {:ok, composition} = CapabilityComposition.compose(low, high)

      assert composition.authority_requirements == %{
               "low" => %{mode: :none},
               "high" => %{mode: :required, scope: "admin", expires_in_s: 60}
             }

      # The low-authority participant did NOT inherit the high one's ceiling.
      assert composition.authority_requirements["low"] == low.authority_requirement
      assert composition.authority_requirements["low"] != high.authority_requirement

      # And the high one was not lowered either -- independence cuts both ways.
      assert composition.authority_requirements["high"] == high.authority_requirement
    end

    test "raises_ceiling?/2 returns [] for a conforming composition" do
      c1 = advance(:open, :mid, id: "c1", authority_requirement: %{mode: :none})
      c2 = advance(:mid, :close, id: "c2", authority_requirement: %{mode: :required})

      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      assert CapabilityComposition.raises_ceiling?(composition, [c1, c2]) == []
    end

    test "raises_ceiling?/2 names exactly the participant whose requirement was altered" do
      c1 = advance(:open, :mid, id: "c1", authority_requirement: %{mode: :none})
      c2 = advance(:mid, :close, id: "c2", authority_requirement: %{mode: :required})

      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      # Simulate the forbidden rollup: c1 is silently granted c2's ceiling.
      escalated = %{
        composition
        | authority_requirements: %{
            "c1" => %{mode: :required},
            "c2" => %{mode: :required}
          }
      }

      assert CapabilityComposition.raises_ceiling?(escalated, [c1, c2]) == ["c1"]
    end

    test "the Composition struct has no aggregate authority field to roll up into" do
      c1 = advance(:open, :mid, id: "c1")
      c2 = advance(:mid, :close, id: "c2")
      {:ok, composition} = CapabilityComposition.compose(c1, c2)

      keys = composition |> Map.from_struct() |> Map.keys()

      refute :effective_authority in keys
      refute :authority_ceiling in keys
      refute :combined_authority in keys
      assert :authority_requirements in keys

      # The only `authority` field is the constant fence.
      assert composition.authority == :none
    end

    test "consequence classes stay per-participant and are not rolled up" do
      observe = advance(:open, :mid, id: "obs", consequence: :observe)
      external = advance(:mid, :close, id: "ext", consequence: :external_do)

      {:ok, composition} = CapabilityComposition.compose(observe, external)

      assert composition.consequence_classes == %{"obs" => :observe, "ext" => :external_do}
    end

    test "authority requirements survive a multi-hop chain unchanged" do
      a = advance(:open, :b, id: "a", authority_requirement: %{mode: :none})
      b = advance(:b, :c, id: "b", authority_requirement: %{mode: :required, scope: "x"})
      c = advance(:c, :close, id: "c", authority_requirement: %{mode: :denied})

      assert {:ok, {compositions, final_state}} = CapabilityComposition.chain([a, b, c])

      assert length(compositions) == 2
      assert final_state == [{"current-phase", ["close"]}]

      # `raises_ceiling?/2` is scoped to a single composition's own
      # participants: hop 0 is a->b, hop 1 is b->c. (Handing it a
      # non-participant correctly reports a discrepancy -- the composition
      # records `nil` for a capability it does not involve -- so each hop is
      # checked against exactly its own two profiles.)
      [ab, bc] = compositions
      assert CapabilityComposition.raises_ceiling?(ab, [a, b]) == []
      assert CapabilityComposition.raises_ceiling?(bc, [b, c]) == []

      # Every declared requirement is still exactly what its own capability
      # declared, nowhere raised by the chaining.
      all = compositions |> Enum.map(& &1.authority_requirements) |> Enum.reduce(&Map.merge/2)

      assert all == %{
               "a" => a.authority_requirement,
               "b" => b.authority_requirement,
               "c" => c.authority_requirement
             }

      # `b` participates in BOTH hops and its requirement is identical in
      # each -- being composed twice did not accumulate anything.
      assert ab.authority_requirements["b"] == bc.authority_requirements["b"]
      assert ab.authority_requirements["b"] == b.authority_requirement
    end
  end

  describe "chaining" do
    test "chain/2 threads real state forward without double-applying effects" do
      a = advance(:open, :mid, id: "a")
      b = advance(:mid, :close, id: "b")

      assert {:ok, {[one], final}} = CapabilityComposition.chain([a, b])

      assert one.resulting_state == [{"current-phase", ["close"]}]
      assert final == [{"current-phase", ["close"]}]
    end

    test "chain/2 reports the failing hop index" do
      a = advance(:open, :mid, id: "a")
      b = advance(:mid, :close, id: "b")
      broken = advance(:nowhere, :elsewhere, id: "broken")

      assert {:error, refusal} = CapabilityComposition.chain([a, b, broken])
      assert refusal.code == :composition_preconditions_unmet
      assert refusal.hop == 1
    end

    test "a single-profile chain yields no compositions and just its own effects" do
      a = advance(:open, :close, id: "a")

      assert {:ok, {[], final}} =
               CapabilityComposition.chain([a], initial_state: [{:"current-phase", [:open]}])

      assert final == [{"current-phase", ["close"]}]
    end
  end

  describe "from_hddl_operator/3 reuses the real compiled capability shape" do
    test "builds a profile from a real AshA2A.Skill and a real AshA2A.HddlOperator" do
      skill = %AshA2A.Skill{id: "meeting/advance", consequence: :change}

      operator = %AshA2A.HddlOperator{
        parameters: [:from, :to],
        preconditions: [{:"current-phase", [:from]}],
        add_effects: [{:"current-phase", [:to]}],
        delete_effects: [{:"current-phase", [:from]}]
      }

      profile =
        CapabilityComposition.from_hddl_operator(skill, operator,
          authority_requirement: %{mode: :required}
        )

      assert profile.capability_id == "meeting/advance"
      assert profile.consequence == :change
      # No fact-shape translation happened -- the tuples came through as-is.
      assert profile.preconditions == operator.preconditions
      assert profile.add_effects == operator.add_effects
      assert profile.delete_effects == operator.delete_effects
      assert profile.authority_requirement == %{mode: :required}
    end
  end
end
