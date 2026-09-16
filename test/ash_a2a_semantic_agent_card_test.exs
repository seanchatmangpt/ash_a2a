defmodule AshA2A.SemanticAgentCardTest do
  @moduledoc """
  RFC-SA2A-001 S10 -- semantic capability declarations.

  Every declaration under test is derived from the **real compiled**
  `AshA2A.CapabilityIndex` of a real `Ash.Resource`
  (`AshA2A.Test.SemanticPeerFixture.Ordering`), which is itself derived from
  `Ash.Resource.Info.public_actions/1`. Nothing here hand-builds a skill
  struct to feed the derivation, so a drift between the semantic declaration
  and the real A2A capability surface would fail these tests rather than
  hide.

  The central assertion is the negative one: a declaration is a statement
  that machinery exists, not a grant. `grant?/1` is `false` for every
  declaration of every consequence class, and the struct carries no field
  that could function as a credential.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{AgentCard, Extension}
  alias AshA2A.Test.SemanticPeerFixture.Ordering

  setup do
    declarations = AgentCard.for_subject(Ordering)
    %{declarations: declarations, by_iri: Map.new(declarations, &{&1.capability_iri, &1})}
  end

  describe "derivation from the real compiled capability index" do
    test "one declaration per real public Ash action, no more and no fewer", %{
      declarations: declarations
    } do
      index = AshA2A.Info.capability_index!(Ordering)

      assert length(declarations) == length(index)
      assert declarations != []

      # The real compiled index for this fixture: `:read`, `:create`, `:destroy`.
      assert Enum.sort(Enum.map(index, & &1.action)) == [:create, :destroy, :read]
    end

    test "capability IRIs are derived from the canonical {resource, action} id", %{
      by_iri: by_iri
    } do
      expected =
        "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create"

      assert Map.has_key?(by_iri, expected)
    end

    test "input and output shape IRIs are declared per capability", %{by_iri: by_iri} do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.input_shape ==
               "urn:sa2a:shape:AshA2A.Test.SemanticPeerFixture.Ordering.create:input"

      assert declaration.output_shape ==
               "urn:sa2a:shape:AshA2A.Test.SemanticPeerFixture.Ordering.create:output"
    end

    test "semantic_basis names canonical Ash introspection, not a second model", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(&1.semantic_basis =~ "ash:public_actions"))
    end

    test "version tracks the negotiated profile version", %{declarations: declarations} do
      assert Enum.all?(declarations, &(&1.version == Extension.profile_version()))
    end
  end

  describe "consequence, authority requirement and receipt class travel together" do
    test "a :read capability is :observe, needs no authority, emits no receipt", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.read")

      assert declaration.consequence_class == :observe
      assert declaration.authority_requirement == :none
      assert declaration.receipt_class == :none
    end

    test "a :create capability is :change, needs CommandBus admission, emits a receipt", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.consequence_class == :change
      assert declaration.authority_requirement == :command_bus_admission
      assert declaration.receipt_class == :command_receipt
    end

    test "a :destroy capability is also consequence-bearing", %{by_iri: by_iri} do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.destroy")

      assert declaration.consequence_class == :change
      assert declaration.authority_requirement == :command_bus_admission
    end

    test "an :unknown consequence maps to :unclassified authority, never to :none" do
      skill = %AshA2A.Skill{
        id: "Some.Resource.mystery",
        resource: Some.Resource,
        action: :mystery,
        consequence: :unknown
      }

      declaration = AgentCard.from_skill(skill)

      # The exact failure mode this guards: an unclassified generic action
      # silently declaring that it needs no authority, and thereby becoming
      # the route a real consequence takes around admission.
      assert declaration.authority_requirement == :unclassified
      refute declaration.authority_requirement == :none
      assert declaration.receipt_class == :command_receipt
    end
  end

  describe "preconditions, effects and planner compatibility come from real declarations" do
    test "declared HDDL operators surface as real precondition and effect terms", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.create")

      assert declaration.preconditions == ["(available item)"]
      assert Enum.sort(declaration.effects) == ["(ordered order)", "not (available item)"]
      assert declaration.planner_compatibility == [:hddl]
    end

    test "a capability with no declared operators claims no planner compatibility", %{
      by_iri: by_iri
    } do
      declaration =
        Map.fetch!(by_iri, "urn:sa2a:capability:AshA2A.Test.SemanticPeerFixture.Ordering.read")

      assert declaration.preconditions == []
      assert declaration.effects == []
      assert declaration.planner_compatibility == []
    end

    test "an undeclared cost envelope is :unbounded, not a fabricated number", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(&1.cost_envelope == :unbounded))
    end
  end

  describe "a declaration is NOT a grant" do
    test "grant?/1 is false for every declaration of every consequence class", %{
      declarations: declarations
    } do
      assert Enum.all?(declarations, &(AgentCard.grant?(&1) == false))
    end

    test "standing/1 is :declaration, never :admitted", %{declarations: declarations} do
      assert Enum.all?(declarations, &(AgentCard.standing(&1) == :declaration))
      refute Enum.any?(declarations, &(AgentCard.standing(&1) == :admitted))
    end

    test "the struct carries no authority token, capability handle or credential", %{
      declarations: [declaration | _]
    } do
      fields = declaration |> Map.from_struct() |> Map.keys() |> Enum.map(&to_string/1)

      # `authority_requirement` states what a caller would need. Nothing here
      # supplies it.
      assert "authority_requirement" in fields

      refute Enum.any?(fields, fn field ->
               field in ~w(authority token credential grant capability_handle secret signature)
             end)
    end

    test "the RDF projection says grantsAuthority false explicitly", %{
      declarations: declarations
    } do
      turtle = AgentCard.to_turtle(declarations)

      assert turtle =~ "sa2a:grantsAuthority false"
      refute turtle =~ "sa2a:grantsAuthority true"
    end
  end

  describe "RDF projection" do
    test "the Turtle projection is accepted and hashed by the REAL GraphLaw engine", %{
      declarations: declarations
    } do
      turtle = AgentCard.to_turtle(declarations)

      case AshA2A.Semantic.GraphLaw.graph_hash(turtle) do
        {:ok, digest} ->
          assert String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

          # The same declarations must hash identically on a second real
          # engine invocation -- a fresh wasm instance, no shared state.
          assert {:ok, ^digest} = AshA2A.Semantic.GraphLaw.graph_hash(turtle)

        {:error, %{code: :graphlaw_unavailable} = refusal} ->
          flunk("""
          The real praxis-graphlaw engine was not reachable, so this test could \
          not verify the RDF projection against it: #{inspect(refusal)}

          This is a real environment failure, not a passing test. Configure \
          :ash_a2a, AshA2A.Semantic.GraphLaw.Wasm, wasm_path: ... or set \
          GRAPHLAW_WASM.
          """)
      end
    end

    test "the projection is byte-stable for the same declarations", %{
      declarations: declarations
    } do
      assert AgentCard.to_turtle(declarations) == AgentCard.to_turtle(declarations)

      # And order-independent in the input list, since declarations are
      # sorted by IRI before rendering.
      assert AgentCard.to_turtle(declarations) ==
               AgentCard.to_turtle(Enum.reverse(declarations))
    end

    test "for_subject/1 on a module with no compiled index returns [], it does not raise" do
      assert AgentCard.for_subject(Enum) == []
    end
  end
end
