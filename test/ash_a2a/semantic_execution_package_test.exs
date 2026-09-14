defmodule AshA2A.Semantic.ExecutionPackageTest do
  use ExUnit.Case, async: true

  alias AshA2A.Planning.Candidate
  alias AshA2A.Semantic.{ExecutionPackage, Ontology, PlanningIR, Source}
  alias AshA2A.Semantic.IR

  defp build_source(text \\ "The system shall greet the user.") do
    Source.new(text)
  end

  defp build_admitted_ir(source) do
    %IR{
      source_id: source.id,
      standing: :admitted,
      authority: :none,
      goals: [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Greet the user",
          "source_quote" => "The system shall greet the user."
        }
      ]
    }
  end

  defp build_ontology(ir) do
    {:ok, ontology} = Ontology.from_ir(ir)
    ontology
  end

  defp build_planning_ir(ir, ontology) do
    {:ok, planning_ir} = PlanningIR.from_ir(ir, ontology)
    planning_ir
  end

  defp build_candidate(plan \\ %{"authority" => "none"}) do
    Candidate.new(:test_planner, plan, [], formalism: :hddl_fond)
  end

  defp build_inputs do
    source = build_source()
    ir = build_admitted_ir(source)
    ontology = build_ontology(ir)
    planning_ir = build_planning_ir(ir, ontology)
    candidate = build_candidate()
    {source, ir, ontology, planning_ir, candidate}
  end

  describe "new/6 happy path" do
    test "returns an ok package with expected defaults" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert %ExecutionPackage{
               standing: :candidate,
               authority: :none,
               parent_fingerprint: nil,
               feedback: []
             } = package

      assert is_binary(package.fingerprint)
      assert String.length(package.fingerprint) == 64
      assert package.fingerprint == String.downcase(package.fingerprint)
      assert package.fingerprint =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "new/6 fence rejections" do
    test "rejects ir with standing not :admitted" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ir = %{ir | standing: :candidate}

      assert ExecutionPackage.new(source, bad_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects ir with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ir = %{ir | authority: :invalid}

      assert ExecutionPackage.new(source, bad_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects ontology with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_ontology = %{ontology | authority: :invalid}

      assert ExecutionPackage.new(source, ir, bad_ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects planning_ir with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_planning_ir = %{planning_ir | authority: :invalid}

      assert ExecutionPackage.new(source, ir, ontology, bad_planning_ir, candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects candidate with standing not :candidate" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_candidate = %{candidate | standing: :admitted}

      assert ExecutionPackage.new(source, ir, ontology, planning_ir, bad_candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end

    test "rejects candidate with authority not :none" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      bad_candidate = %{candidate | authority: :invalid}

      assert ExecutionPackage.new(source, ir, ontology, planning_ir, bad_candidate) ==
               {:error, %{code: :semantic_package_authority_ceiling_violated}}
    end
  end

  describe "new/6 opts threading" do
    test "threads parent_fingerprint and feedback when provided" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} =
               ExecutionPackage.new(source, ir, ontology, planning_ir, candidate,
                 parent_fingerprint: "parent-1",
                 feedback: [%{"k" => "v"}]
               )

      assert package.parent_fingerprint == "parent-1"
      assert package.feedback == [%{"k" => "v"}]
    end

    test "defaults parent_fingerprint to nil and feedback to [] without opts" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert package.parent_fingerprint == nil
      assert package.feedback == []
    end
  end

  describe "fingerprint determinism/sensitivity" do
    test "identical inputs produce identical fingerprints" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)
      assert {:ok, package_b} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      assert package_a.fingerprint == package_b.fingerprint
    end

    test "changing the source changes the fingerprint" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      other_source = build_source("A completely different source statement.")
      other_ir = %{ir | source_id: other_source.id}

      assert {:ok, package_b} =
               ExecutionPackage.new(other_source, other_ir, ontology, planning_ir, candidate)

      refute package_a.fingerprint == package_b.fingerprint
    end

    test "changing the candidate's plan content changes the fingerprint" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert {:ok, package_a} = ExecutionPackage.new(source, ir, ontology, planning_ir, candidate)

      other_candidate = build_candidate(%{"authority" => "none", "extra" => "different-plan"})
      refute other_candidate.fingerprint == candidate.fingerprint

      assert {:ok, package_b} =
               ExecutionPackage.new(source, ir, ontology, planning_ir, other_candidate)

      refute package_a.fingerprint == package_b.fingerprint
    end
  end
end
