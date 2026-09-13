defmodule AshA2A.Planning.SemanticSynthesisTest do
  use ExUnit.Case, async: false

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
end
