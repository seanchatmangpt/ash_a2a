defmodule AshA2A.Planning.SemanticSynthesisTest do
  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.Planning.SemanticSynthesis
  alias AshA2A.Test.Fixture.Echo

  setup do
    previous = Application.get_env(:ash_a2a, :llm_profiles, [])

    Application.put_env(:ash_a2a, :llm_profiles,
      surface_planner: [provider: :zai_coder, model: "glm-5.3-flash", max_tokens: 4096]
    )

    on_exit(fn -> Application.put_env(:ash_a2a, :llm_profiles, previous) end)
  end

  test "ZAI role can synthesize a candidate but cannot gain DO authority" do
    generator = fn model_spec, prompt, schema, opts ->
      assert model_spec == "zai_coder:glm-5.3-flash"
      assert opts[:max_tokens] == 4096
      assert prompt =~ "Canonical capability ids"
      assert get_in(schema, ["properties", "authority", "enum"]) == ["none"]

      {:ok,
       %{
         "request_id" => "surface-plan-1",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "(:task inspect-surface)",
         "fond" => "(:policy observe-or-replan)",
         "rationale" => "observe before selecting"
       }}
    end

    assert {:ok, candidate} =
             SemanticSynthesis.synthesize(
               Echo,
               "verify the accessible surface",
               %{"aria" => [%{"role" => "button", "name" => "Continue"}]},
               generate_object: generator
             )

    assert candidate.planner == :semantic_synthesis
    assert candidate.formalism == :hddl_fond
    assert candidate.standing == :candidate
    assert candidate.authority == :none
    assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]
    assert candidate.plan["authority"] == "none"
    assert candidate.plan["synthesis"]["role"] == "surface_planner"
  end

  test "semantic model authority claims are refused before capability admission" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-do",
         "authority" => "do",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :planner_authority_ceiling_violated}} =
             SemanticSynthesis.synthesize(Echo, "actuate", %{}, generate_object: generator)
  end

  test "noncanonical model-selected capability is refused by canonical A2A admission" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-invalid-capability",
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.delete_everything"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :noncanonical_capability}} =
             SemanticSynthesis.synthesize(Echo, "invent a capability", %{},
               generate_object: generator
             )
  end

  defmodule NoCapabilities.Resource do
    @moduledoc """
    Real fixture resource, local to this test file, with `extensions:
    [AshA2A]` attached but zero public actions (`defaults([])`) and no `a2a
    do skill ... end` block -- so `AshA2A.CapabilityIndex.Compiler.compile/3`
    has zero `Ash.Resource.Info.public_actions/1` to project and zero
    overrides, yielding a provably empty capability index for the
    `:no_canonical_capabilities` short-circuit test below.
    """

    use Ash.Resource,
      domain: AshA2A.Planning.SemanticSynthesisTest.NoCapabilities.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshA2A]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([])
    end
  end

  defmodule NoCapabilities.Domain do
    @moduledoc """
    Real fixture domain pairing `NoCapabilities.Resource` above, mirroring
    `AshA2A.Test.Fixture.Domain`'s shape.
    """

    use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

    resources do
      resource(AshA2A.Planning.SemanticSynthesisTest.NoCapabilities.Resource)
    end
  end

  test ":no_canonical_capabilities short-circuits before any generate_object call" do
    assert SemanticSynthesis.capability_ids(NoCapabilities.Domain) == []

    generator = fn _model_spec, _prompt, _schema, _opts ->
      raise "must not be called"
    end

    assert {:error, %{code: :no_canonical_capabilities}} =
             SemanticSynthesis.synthesize(NoCapabilities.Domain, "some goal", %{},
               generate_object: generator
             )
  end

  test "invalid_semantic_plan_shape: empty capability_ids list" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-empty",
         "authority" => "none",
         "capability_ids" => [],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: non-string capability id" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "request_id" => "surface-plan-nonstring",
         "authority" => "none",
         "capability_ids" => [123],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: missing request_id" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok,
       %{
         "authority" => "none",
         "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
         "hddl" => "candidate",
         "fond" => "candidate"
       }}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "invalid_semantic_plan_shape: proposal is not a map" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:ok, "not a map at all"}
    end

    assert {:error, %{code: :invalid_semantic_plan_shape}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "semantic_synthesis_failed wraps a raw non-code error reason" do
    generator = fn _model_spec, _prompt, _schema, _opts ->
      {:error, "raw reason string"}
    end

    assert {:error, %{code: :semantic_synthesis_failed, detail: "raw reason string"}} =
             SemanticSynthesis.synthesize(Echo, "goal", %{}, generate_object: generator)
  end

  test "capability_ids/1 returns the sorted, stringified canonical Echo capability ids" do
    assert SemanticSynthesis.capability_ids(Echo) == ["AshA2A.Test.Fixture.Echo.read"]
  end

  test "authority ceiling admits ONLY the literal string \"none\", closed over every other representation" do
    # Fuzz/regression coverage for `normalize_proposal/2`'s real authority
    # check (`if authority == "none" do ... else {:error,
    # refusal(:planner_authority_ceiling_violated, authority)} end`, reading
    # the value via `field/2` = `Map.get(map, "authority") || Map.get(map,
    # :authority)`). Every case below keeps `capability_ids`, `hddl`, and
    # `fond` well-formed and schema-valid so the only variable under test is
    # the literal value returned for "authority" -- proving the ceiling is a
    # closed, exact-string comparison and not a loose truthiness/type check.
    base = %{
      "capability_ids" => ["AshA2A.Test.Fixture.Echo.read"],
      "hddl" => "(:task inspect-surface)",
      "fond" => "(:policy observe-or-replan)"
    }

    cases = [
      {"exact literal string", "none", :ok},
      {"uppercase", "NONE", {:error, :planner_authority_ceiling_violated, "NONE"}},
      {"atom :none", :none, {:error, :planner_authority_ceiling_violated, :none}},
      {"trailing space", "none ", {:error, :planner_authority_ceiling_violated, "none "}},
      {"capitalized", "None", {:error, :planner_authority_ceiling_violated, "None"}},
      {"nil", nil, {:error, :planner_authority_ceiling_violated, nil}},
      {"boolean true", true, {:error, :planner_authority_ceiling_violated, true}},
      {"admin string", "admin", {:error, :planner_authority_ceiling_violated, "admin"}},
      {"do string", "do", {:error, :planner_authority_ceiling_violated, "do"}},
      {"integer zero", 0, {:error, :planner_authority_ceiling_violated, 0}},
      {"empty list", [], {:error, :planner_authority_ceiling_violated, []}}
    ]

    for {label, authority_value, expected} <- cases do
      request_id = "authority-fuzz-" <> String.replace(label, " ", "-")

      generator = fn _model_spec, _prompt, _schema, _opts ->
        {:ok, Map.merge(base, %{"request_id" => request_id, "authority" => authority_value})}
      end

      result =
        SemanticSynthesis.synthesize(Echo, "probe authority ceiling", %{},
          generate_object: generator
        )

      case expected do
        :ok ->
          assert {:ok, candidate} = result
          assert candidate.plan["authority"] == "none"
          assert candidate.authority == :none
          assert candidate.capability_ids == ["AshA2A.Test.Fixture.Echo.read"]

        {:error, code, detail} ->
          assert {:error, %{code: ^code, detail: ^detail}} = result
      end
    end
  end
end
