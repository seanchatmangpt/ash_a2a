defmodule AshA2A.Chicago.Hardening.BoundsExhaustionTest do
  @moduledoc """
  Resource-bounds exhaustion hardening for `AshA2A.Semantic.Bounds` and
  `AshA2A.Semantic.Allocator` (RFC-SA2A-001 §34 Bounded Fan-Out/Depth/
  Parallelism, §35 Resource Bounds, §73 "no blank check" — the same S73
  no-self-grant law `AshA2A.Semantic.Allocator`'s moduledoc cites).

  Every scenario here plays the adversary genuinely, not rhetorically: a
  worker/subtask actually tries to widen its own envelope, overshoot
  fan-out/depth/parallelism, escalate its delegated capability set past its
  immediate parent's, or self-grant exhausted budget. Every attempt is
  asserted to fail closed with a real typed refusal -- never a silent
  clamp, never a crash, never an admitted-anyway grant. Several tests are
  genuine stress runs (hundreds of real recursive delegations, real
  concurrent `Task.async_stream` adversaries, `StreamData` combinatorial
  sweeps), not single-shot spot checks.

  Chicago style throughout: real `AshA2A.Semantic.Bounds` /
  `AshA2A.Semantic.Allocator` structs and real concurrent processes, no
  mocks -- both modules are pure value types with no collaborator to fake.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.Bounds

  # --------------------------------------------------------------------
  # fixtures
  # --------------------------------------------------------------------

  defp envelope(opts) do
    {:ok, bounds} =
      Bounds.new(
        Keyword.merge(
          [
            fan_out: 4,
            depth: 3,
            parallelism: 4,
            resources: %{tokens: 1_000, external_requests: 10},
            capabilities: ["Res.read", "Res.write"]
          ],
          opts
        )
      )

    bounds
  end

  defp small_ceiling_gen, do: StreamData.integer(1..25)
  defp overshoot_gen, do: StreamData.integer(1..1_000_000)

  # --------------------------------------------------------------------
  # 1. no self-grant: a worker cannot enlarge its own delegated envelope
  #    (RFC-SA2A-001 S73 -- no blank check)
  # --------------------------------------------------------------------

  describe "no self-grant: a worker cannot enlarge its own delegated envelope" do
    property "every ceiling widened above the parent's, by any amount, is refused" do
      check all(
              ceiling <- small_ceiling_gen(),
              overshoot <- overshoot_gen(),
              field <- StreamData.member_of([:fan_out, :parallelism])
            ) do
        parent = envelope([{field, ceiling}, {:depth, 1}])

        assert {:error, %{code: :bounds_delegation_not_narrowing, detail: detail}} =
                 Bounds.delegate(parent, [{field, ceiling + overshoot}])

        assert detail.field == field
        assert detail.parent == ceiling
        assert detail.requested == ceiling + overshoot
      end
    end

    property "depth widened above D_max - 1, by any amount, is refused" do
      check all(
              depth <- small_ceiling_gen(),
              overshoot <- overshoot_gen()
            ) do
        parent = envelope(depth: depth)
        narrow_ceiling = depth - 1

        assert {:error, %{code: :bounds_delegation_not_narrowing, detail: detail}} =
                 Bounds.delegate(parent, depth: narrow_ceiling + overshoot)

        assert detail.field == :depth
        assert detail.parent == narrow_ceiling
      end
    end

    property "a negative ceiling request is refused the same way as an overshoot, never treated as extra headroom" do
      check all(
              ceiling <- small_ceiling_gen(),
              negative <- StreamData.integer(-1_000_000..-1),
              field <- StreamData.member_of([:fan_out, :depth, :parallelism])
            ) do
        parent = envelope([{field, ceiling}])

        assert {:error, %{code: :bounds_delegation_not_narrowing}} =
                 Bounds.delegate(parent, [{field, negative}])
      end
    end

    property "a resource widened past what remains, at any key and any overshoot, is refused" do
      check all(
              remaining <- StreamData.integer(0..1_000),
              overshoot <- overshoot_gen(),
              key <- StreamData.member_of([:tokens, :external_requests])
            ) do
        parent = envelope(resources: %{key => remaining})

        assert {:error, %{code: :bounds_delegation_not_narrowing, detail: detail}} =
                 Bounds.delegate(parent, resources: %{key => remaining + overshoot})

        assert detail.field == {:resources, key}
        assert detail.parent == remaining
        assert detail.requested == remaining + overshoot
      end
    end

    test "a worker holding a stale, un-widened request for every field at once is still refused on one call" do
      parent = envelope(fan_out: 2, depth: 2, parallelism: 2, resources: %{tokens: 10})

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(parent,
                 fan_out: 3,
                 parallelism: 3,
                 resources: %{tokens: 11},
                 capabilities: ["Res.read", "Res.write"]
               )
    end

    test "omitting `resources` from a delegation grants the child NOTHING -- never the parent's full budget" do
      parent = envelope(resources: %{tokens: 1_000, external_requests: 10})

      assert {:ok, %{child: child}} = Bounds.delegate(parent, [])
      assert child.resources == %{}

      # And a child with no resource entry for a key cannot spend against it
      # by claiming the parent's silence was an implicit grant.
      assert Bounds.consume(child, :tokens, 1) ==
               {:error, %{code: :bounds_resource_unknown, detail: :tokens}}
    end

    test "omitting `capabilities` from a delegation inherits exactly the parent's set, never more" do
      parent = envelope(capabilities: ["Res.read", "Res.write"])

      assert {:ok, %{child: child}} = Bounds.delegate(parent, [])
      assert child.capabilities == parent.capabilities
    end

    property "Allocator.request_increase/2 refuses self-grant for any request payload shape" do
      check all(
              payload <-
                StreamData.one_of([
                  StreamData.map_of(StreamData.string(:alphanumeric), StreamData.integer()),
                  StreamData.constant(%{"authority" => "admin"}),
                  StreamData.constant(nil),
                  StreamData.list_of(StreamData.integer()),
                  StreamData.string(:alphanumeric)
                ])
            ) do
        budget = Allocator.new!([tokens: 10], issued_by: {:host, __MODULE__})

        assert {:error, %{code: :self_grant_refused, requested: ^payload}} =
                 Allocator.request_increase(budget, payload)

        # Genuinely unchanged by having been asked.
        assert Allocator.remaining(budget) == %{tokens: 10}
      end
    end

    property "a negative Allocator.allocate amount (a disguised refund) is refused on every real dimension" do
      check all(
              dimension <- StreamData.member_of(Allocator.dimensions()),
              negative <- StreamData.integer(-1_000_000..-1)
            ) do
        budget = Allocator.new!([{dimension, 100}], issued_by: {:host, __MODULE__})

        assert {:error, %{code: :invalid_allocation_amount, dimension: ^dimension}} =
                 Allocator.allocate(budget, dimension, negative)

        # No headroom was manufactured by the attempt. `:wall_time_ms` is a
        # MEASURED dimension (`limit - elapsed`, see `Allocator.remaining/1`),
        # so real elapsed time may legitimately shrink it below the limit
        # between `new!` and here; the refund attempt must only never GROW it.
        remaining = Allocator.remaining(budget)[dimension]

        if dimension == :wall_time_ms do
          assert remaining <= 100
        else
          assert remaining == 100
        end
      end
    end

    property "Allocator.reissue/3 refuses any forged issuer that is neither a {:host, _} tuple nor a real non-model Authority" do
      check all(
              forged <-
                StreamData.one_of([
                  StreamData.string(:alphanumeric),
                  StreamData.constant(%{}),
                  StreamData.constant(nil),
                  StreamData.constant([:host, :not_a_tuple]),
                  StreamData.constant({:worker, "compromised"}),
                  StreamData.constant({:model, "the model itself"})
                ])
            ) do
        budget = Allocator.new!([tokens: 10], issued_by: {:host, __MODULE__})

        assert {:error, %{code: code}} = Allocator.reissue(budget, forged, tokens: 1_000)
        assert code in [:invalid_budget_issuer, :model_issued_budget_refused]
      end
    end
  end

  # --------------------------------------------------------------------
  # 2. fan-out ceiling: F_max cannot be exceeded
  # --------------------------------------------------------------------

  describe "fan-out ceiling: F_max cannot genuinely be exceeded" do
    property "admit_fan_out/2 admits exactly at the ceiling and refuses everything above it" do
      check all(ceiling <- small_ceiling_gen(), overshoot <- overshoot_gen()) do
        bounds = envelope(fan_out: ceiling)

        assert Bounds.admit_fan_out(bounds, ceiling) == :ok

        assert {:error, %{code: :bounds_fan_out_exceeded, detail: detail}} =
                 Bounds.admit_fan_out(bounds, ceiling + overshoot)

        assert detail == %{ceiling: ceiling, requested: ceiling + overshoot}
      end
    end

    test "a zero fan-out ceiling admits nothing at all, including a single fan-out delegate" do
      parent = envelope(fan_out: 0)

      assert Bounds.admit_fan_out(parent, 0) == :ok
      assert {:error, %{code: :bounds_fan_out_exceeded}} = Bounds.admit_fan_out(parent, 1)
      assert {:ok, %{child: child}} = Bounds.delegate(parent, [])
      assert child.fan_out == 0
    end
  end

  # --------------------------------------------------------------------
  # 3. depth ceiling: D_max cannot be exceeded under sustained adversarial
  #    recursion (RFC-SA2A-001 S34, real stress run)
  # --------------------------------------------------------------------

  describe "depth ceiling: D_max cannot be exceeded, even under sustained real recursion" do
    test "a legitimate recursive delegation chain bottoms out at exactly D_max hops, never one hop more" do
      for d_max <- [1, 2, 5, 50, 500] do
        parent = envelope(depth: d_max, fan_out: 10_000, parallelism: 10_000)

        final =
          Enum.reduce(1..d_max, parent, fn hop, current ->
            assert {:ok, %{child: child}} = Bounds.delegate(current, [])
            assert child.depth == d_max - hop
            child
          end)

        assert final.depth == 0

        assert Bounds.delegate(final, []) ==
                 {:error, %{code: :bounds_depth_exhausted, detail: 0}}
      end
    end

    test "at every hop, an attacker requesting the un-narrowed (current) depth is refused before it ever bottoms out" do
      d_max = 200
      parent = envelope(depth: d_max, fan_out: 10_000, parallelism: 10_000)

      Enum.reduce(1..d_max, parent, fn _hop, current ->
        # The attacker's move: ask to keep the SAME depth as the current
        # envelope instead of narrowing, hoping the ceiling silently holds.
        assert {:error, %{code: :bounds_delegation_not_narrowing}} =
                 Bounds.delegate(current, depth: current.depth)

        # The lawful move still succeeds and genuinely narrows.
        assert {:ok, %{child: child}} = Bounds.delegate(current, [])
        assert child.depth == current.depth - 1
        child
      end)
      |> then(fn bottom ->
        assert bottom.depth == 0

        assert Bounds.delegate(bottom, []) ==
                 {:error, %{code: :bounds_depth_exhausted, detail: 0}}
      end)
    end
  end

  # --------------------------------------------------------------------
  # 4. parallelism ceiling: P_max cannot be exceeded, including under real
  #    concurrent adversarial load
  # --------------------------------------------------------------------

  describe "parallelism ceiling: P_max cannot be exceeded" do
    property "admit_parallelism/2 admits exactly at the ceiling and refuses everything above it" do
      check all(ceiling <- small_ceiling_gen(), overshoot <- overshoot_gen()) do
        bounds = envelope(parallelism: ceiling)

        assert Bounds.admit_parallelism(bounds, ceiling) == :ok

        assert {:error, %{code: :bounds_parallelism_exceeded, detail: detail}} =
                 Bounds.admit_parallelism(bounds, ceiling + overshoot)

        assert detail == %{ceiling: ceiling, requested: ceiling + overshoot}
      end
    end

    test "under real concurrent load, exactly the workers at-or-under P_max are admitted, no more" do
      ceiling = 8
      bounds = envelope(parallelism: ceiling)

      results =
        1..64
        |> Task.async_stream(&Bounds.admit_parallelism(bounds, &1), max_concurrency: 64)
        |> Enum.map(fn {:ok, result} -> result end)

      admitted = Enum.count(results, &(&1 == :ok))
      refused = Enum.count(results, &match?({:error, %{code: :bounds_parallelism_exceeded}}, &1))

      assert admitted == ceiling
      assert refused == 64 - ceiling
    end

    test "under real concurrent load, every worker trying to widen parallelism via delegate is refused, none crash" do
      ceiling = 4
      total_workers = ceiling * 10
      parent = envelope(parallelism: ceiling, depth: 2)

      results =
        1..total_workers
        |> Task.async_stream(
          fn requested -> Bounds.delegate(parent, parallelism: requested) end,
          max_concurrency: total_workers
        )
        # `{:ok, result}` is Task.async_stream/3's own success envelope, not
        # `Bounds.delegate/2`'s -- a crashed/timed-out worker would surface
        # as `{:exit, reason}` here instead and fail this match, so a clean
        # match across all `total_workers` is itself proof none crashed.
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == total_workers

      admitted = Enum.count(results, &match?({:ok, _}, &1))

      refused =
        Enum.count(results, &match?({:error, %{code: :bounds_delegation_not_narrowing}}, &1))

      assert admitted == ceiling
      assert refused == total_workers - ceiling
    end
  end

  # --------------------------------------------------------------------
  # 5. a delegated child cannot claim broader authority-scope (capability
  #    envelope) than its immediate parent delegated it
  #    (Authority(child) subset-of Authority(parent))
  # --------------------------------------------------------------------

  describe "a delegated child cannot escalate its capability envelope past its immediate parent" do
    test "requesting a capability the parent never held at all is refused, naming exactly that capability" do
      parent = envelope(capabilities: ["Res.read"])

      assert {:error,
              %{
                code: :bounds_delegation_not_narrowing,
                detail: %{field: :capabilities, requested: requested}
              }} =
               Bounds.delegate(parent, capabilities: ["Res.destroy"])

      assert requested == ["Res.destroy"]
    end

    test "the parent's full set plus one extra (escalation-by-one) is refused, naming only the extra one" do
      parent = envelope(capabilities: ["Res.read", "Res.write"])

      assert {:error,
              %{
                code: :bounds_delegation_not_narrowing,
                detail: %{field: :capabilities, requested: escalated}
              }} =
               Bounds.delegate(parent, capabilities: ["Res.read", "Res.write", "Res.admin"])

      assert escalated == ["Res.admin"]
    end

    test "confused-deputy: a grandchild cannot regain a capability its immediate parent (a child) had narrowed away, even though the root ancestor held it" do
      root = envelope(capabilities: ["Res.read", "Res.write", "Res.admin"], depth: 3)

      assert {:ok, %{child: narrow_child}} =
               Bounds.delegate(root, capabilities: ["Res.read"])

      assert narrow_child.capabilities == MapSet.new(["Res.read"])

      # narrow_child's own delegated envelope no longer carries "Res.write"
      # or "Res.admin" -- even though the root ancestor did.
      assert {:error, %{code: :bounds_delegation_not_narrowing, detail: %{requested: requested}}} =
               Bounds.delegate(narrow_child, capabilities: ["Res.read", "Res.write"])

      assert requested == ["Res.write"]

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(narrow_child, capabilities: ["Res.admin"])
    end

    test "confused-deputy: a sibling cannot borrow a capability delegated only to another sibling" do
      parent = envelope(capabilities: ["X.read", "Y.write"], depth: 3, resources: %{tokens: 100})

      assert {:ok, %{child: sibling_a, parent: after_a}} =
               Bounds.delegate(parent, capabilities: ["X.read"], resources: %{tokens: 50})

      assert {:ok, %{child: sibling_b}} =
               Bounds.delegate(after_a, capabilities: ["Y.write"], resources: %{tokens: 50})

      assert sibling_a.capabilities == MapSet.new(["X.read"])
      assert sibling_b.capabilities == MapSet.new(["Y.write"])

      # sibling_a reaching for sibling_b's capability is refused -- the
      # common parent having held both does not make it sibling_a's.
      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(sibling_a, capabilities: ["Y.write"])

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(sibling_b, capabilities: ["X.read"])
    end

    test "capability comparison is exact-match: no case, whitespace, or structural near-miss admits a bypass" do
      parent = envelope(capabilities: ["Res.read"])

      for bogus <- [" Res.read", "Res.read ", "RES.READ", "Res.read\n", "res.read"] do
        assert {:error, %{code: :bounds_delegation_not_narrowing}} =
                 Bounds.delegate(parent, capabilities: [bogus]),
               "expected #{inspect(bogus)} to be refused as distinct from \"Res.read\""
      end
    end

    test "a non-list, non-string capabilities value (an injection attempt) is refused, never smuggled through as a member" do
      parent = envelope(capabilities: ["Res.read"])

      # A bare MapSet is wrapped as a single non-string element by
      # `List.wrap/1` inside `narrowed_capabilities/2`, which can never be a
      # member of a parent capability set built entirely from strings.
      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(parent, capabilities: MapSet.new(["Res.read"]))

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(parent, capabilities: [:"Res.read"])

      assert {:error, %{code: :bounds_delegation_not_narrowing}} =
               Bounds.delegate(parent, capabilities: [123])
    end
  end

  # --------------------------------------------------------------------
  # 6. combined kitchen-sink escalation: fails closed as one refusal, never
  #    a partial grant
  # --------------------------------------------------------------------

  describe "a combined multi-field escalation attempt fails closed as one refusal, never a partial grant" do
    test "widening every field at once, plus injecting authority, still yields exactly one typed refusal" do
      parent = envelope(fan_out: 1, depth: 1, parallelism: 1, resources: %{tokens: 1})

      assert {:error, %{code: code}} =
               Bounds.delegate(parent,
                 fan_out: 99,
                 depth: 99,
                 parallelism: 99,
                 resources: %{tokens: 99},
                 capabilities: ["Res.read", "Res.write", "Res.admin"],
                 authority: :granted
               )

      assert is_atom(code)
    end

    property "any single-field overshoot among five plausible attack vectors is refused, never admitted" do
      check all(
              fan_out <- StreamData.integer(1..20),
              depth <- StreamData.integer(1..10),
              parallelism <- StreamData.integer(1..10),
              tokens <- StreamData.integer(0..1_000),
              overshoot <- StreamData.integer(1..10_000),
              target <-
                StreamData.member_of([:fan_out, :depth, :parallelism, :tokens, :capability])
            ) do
        parent =
          envelope(
            fan_out: fan_out,
            depth: depth,
            parallelism: parallelism,
            resources: %{tokens: tokens},
            capabilities: ["Res.read", "Res.write"]
          )

        legal_request = [
          fan_out: fan_out,
          depth: depth - 1,
          parallelism: parallelism,
          resources: %{tokens: tokens},
          capabilities: ["Res.read", "Res.write"]
        ]

        attack_request =
          case target do
            :fan_out ->
              Keyword.put(legal_request, :fan_out, fan_out + overshoot)

            :depth ->
              Keyword.put(legal_request, :depth, depth - 1 + overshoot)

            :parallelism ->
              Keyword.put(legal_request, :parallelism, parallelism + overshoot)

            :tokens ->
              Keyword.put(legal_request, :resources, %{tokens: tokens + overshoot})

            :capability ->
              Keyword.put(legal_request, :capabilities, [
                "Res.read",
                "Res.write",
                "Res.forbidden-#{overshoot}"
              ])
          end

        assert {:error, %{code: code}} = Bounds.delegate(parent, attack_request)
        assert is_atom(code)
      end
    end
  end
end
