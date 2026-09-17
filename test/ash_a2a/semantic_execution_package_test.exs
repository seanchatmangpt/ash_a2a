defmodule AshA2A.Semantic.ExecutionPackageTest do
  use ExUnit.Case, async: true

  alias AshA2A.Planning.Candidate

  alias AshA2A.Semantic.{
    Admission,
    ExecutionPackage,
    IR,
    IrAdmissionSeal,
    Ontology,
    PlanningIR,
    Source
  }

  defp build_source(text \\ "The system shall greet the user.") do
    Source.new(text)
  end

  # Real admission, not a hand-set `standing: :admitted`: `IR.from_map/2`
  # builds a genuine `:candidate` IR and `Admission.admit/2` runs its full
  # provenance/grounding/goal check chain for real, so the returned IR
  # carries a real `AshA2A.Semantic.IrAdmissionSeal`-minted seal. See
  # "new/6 fence rejections" below for the hand-built, unsealed counterpart
  # this module's seal exists to refuse.
  defp build_admitted_ir(source) do
    payload = %{
      "authority" => "none",
      "goals" => [
        %{
          "id" => "goal-1",
          "kind" => "goal",
          "description" => "Greet the user",
          "source_quote" => source.text
        }
      ]
    }

    {:ok, candidate_ir} = IR.from_map(source.id, payload)
    {:ok, ir} = Admission.admit(source, candidate_ir)
    ir
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

    test "rejects a hand-built admitted ir carrying no admission seal" do
      # This is the exact gap `AshA2A.Semantic.IrAdmissionSeal` closes: a
      # struct literal claiming `standing: :admitted, authority: :none`
      # without ever having run `AshA2A.Semantic.Admission.admit/2`. Before
      # the seal existed, this was accepted by `ExecutionPackage.new/6`
      # identically to a real admission.
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      forged_ir = %IR{
        source_id: source.id,
        standing: :admitted,
        authority: :none,
        goals: ir.goals
      }

      refute forged_ir.admission_seal
      refute forged_ir.admission_receipt_id

      assert ExecutionPackage.new(source, forged_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_unsealed, detail: %{source_id: source.id}}}
    end

    test "rejects a real admitted ir whose admission_seal has been tampered with" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()
      assert is_binary(ir.admission_seal)

      tampered_ir = %{ir | admission_seal: "hmac-sha256:" <> String.duplicate("0", 64)}

      assert ExecutionPackage.new(source, tampered_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_seal_invalid, detail: %{source_id: source.id}}}
    end

    test "rejects a real admitted ir whose content changed after sealing" do
      {source, ir, ontology, planning_ir, candidate} = build_inputs()

      [goal] = ir.goals
      retitled_goal = %{goal | "description" => "Greet the user warmly"}
      mutated_ir = %{ir | goals: [retitled_goal]}

      assert ExecutionPackage.new(source, mutated_ir, ontology, planning_ir, candidate) ==
               {:error, %{code: :semantic_ir_seal_invalid, detail: %{source_id: source.id}}}
    end

    test "IrAdmissionSeal.verify/1 accepts a real admitted ir directly" do
      {_source, ir, _ontology, _planning_ir, _candidate} = build_inputs()
      assert IrAdmissionSeal.verify(ir) == :ok
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
      other_ir = build_admitted_ir(other_source)
      other_ontology = build_ontology(other_ir)
      other_planning_ir = build_planning_ir(other_ir, other_ontology)

      assert {:ok, package_b} =
               ExecutionPackage.new(
                 other_source,
                 other_ir,
                 other_ontology,
                 other_planning_ir,
                 candidate
               )

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
