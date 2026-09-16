defmodule AshA2A.SemanticRefusalTest do
  @moduledoc """
  Chicago-school tests for `AshA2A.Semantic.Refusal` (RFC-SA2A-001 S42).

  Real structs, real atoms, real files on disk. The totality test below
  reads the actual `lib/**/*.ex` sources from the filesystem and extracts
  the real refusal codes in use -- it is not a hand-copied list that can
  drift from the code it claims to cover. No mocking of anything: there is
  nothing here to mock, and nothing is stubbed.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal

  describe "taxonomy" do
    test "all 18 S42 classes are present and partitioned" do
      assert length(Refusal.classes()) == 18
      assert length(Refusal.refused_classes()) == 15
      assert Refusal.blocked_classes() == [:blocked_unknown, :blocked_resource]
      assert Refusal.unsupported_classes() == [:unsupported_profile]

      assert Refusal.refused_classes() ++
               Refusal.blocked_classes() ++ Refusal.unsupported_classes() ==
               Refusal.classes()

      assert Enum.uniq(Refusal.classes()) == Refusal.classes()
    end

    test "every RFC S42 class name is a real atom in the taxonomy" do
      rfc_classes = [
        :refused_identity,
        :refused_namespace,
        :refused_structure,
        :refused_shacl,
        :refused_rule,
        :refused_falsifier,
        :refused_provenance,
        :refused_profile,
        :refused_plan,
        :refused_capability,
        :refused_authority,
        :refused_consequence,
        :refused_receipt,
        :refused_bounds,
        :refused_meta_rigor,
        :blocked_unknown,
        :blocked_resource,
        :unsupported_profile
      ]

      for class <- rfc_classes do
        assert Refusal.class?(class), "#{class} missing from taxonomy"
      end
    end

    test "class?/1 rejects a non-class" do
      refute Refusal.class?(:refused_vibes)
      refute Refusal.class?("refused_identity")
    end
  end

  describe "new/4" do
    test "builds a real struct carrying class, code, stage, detail and lawful?" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize, %{scope: "w:r"})

      assert %Refusal{
               class: :refused_authority,
               code: :authority_required,
               stage: :authorize,
               detail: %{scope: "w:r"},
               lawful?: true
             } = refusal
    end

    test "a refusal is lawful, not an error -- the flag is always true" do
      for class <- Refusal.classes() do
        assert Refusal.new(class, :some_code, :some_stage).lawful? == true
      end
    end

    test "raises on an unknown class (programmer error, not a runtime refusal)" do
      assert_raise ArgumentError, ~r/invalid AshA2A.Semantic.Refusal/, fn ->
        Refusal.new(:refused_vibes, :whatever, :stage)
      end
    end
  end

  describe "classify/1 is total over the codes actually present in lib/" do
    test "every refusal code found on disk is explicitly mapped" do
      codes = codes_in_lib()

      # Guard the guard: if the extraction stops finding codes, this test
      # would vacuously pass. The measured count at the time this was
      # written was 70 distinct codes.
      assert length(codes) >= 60,
             "extracted only #{length(codes)} codes from lib/ -- extraction is probably broken"

      mapping = Refusal.mapping()
      unmapped = Enum.reject(codes, &Map.has_key?(mapping, &1))

      assert unmapped == [],
             "these real refusal codes in lib/ have no explicit S42 class: #{inspect(unmapped)}"
    end

    test "every mapped class is a real taxonomy class" do
      for {code, class} <- Refusal.mapping() do
        assert Refusal.class?(class), "#{code} maps to non-class #{inspect(class)}"
      end
    end

    test "classify/1 never raises and always returns a class, mapped or not" do
      assert Refusal.classify(:authority_required) == :refused_authority
      assert Refusal.classify(:consequence_unclassified) == :refused_consequence
      assert Refusal.classify(:invalid_goal_facts) == :refused_structure
      assert Refusal.classify(:ambiguous_goal_facts_shape) == :refused_structure
      assert Refusal.classify(:ungrounded_assertion) == :refused_provenance
      assert Refusal.classify(:semantic_authority_ceiling_violated) == :refused_authority
      assert Refusal.classify(:hddl_cli_not_built) == :blocked_resource
      assert Refusal.classify(:unknown_profile) == :unsupported_profile

      # Unmapped: an honest "no classification exists", not a crash.
      assert Refusal.classify(:a_code_that_has_never_existed) == :blocked_unknown
      assert Refusal.class?(Refusal.classify(:another_unmapped_code))
    end

    defp codes_in_lib do
      patterns = [
        ~r/code:\s+:([a-z_0-9]+)/,
        ~r/error\(:([a-z_0-9]+)/,
        ~r/refusal\(:([a-z_0-9]+)/,
        ~r/\{:error,\s+:([a-z_0-9]+)\}/
      ]

      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        Enum.flat_map(patterns, fn pattern ->
          pattern
          |> Regex.scan(source, capture: :all_but_first)
          |> Enum.map(fn [code] -> String.to_atom(code) end)
        end)
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  describe "from_error/2 maps existing codes without renaming them" do
    test "the AshA2A.CommandBus refusal shape keeps its original code" do
      # The real shape CommandBus.refusal/1 produces.
      commandbus_refusal = %{code: :authority_required, detail: "authority_required"}

      refusal = Refusal.from_error({:error, commandbus_refusal}, :authorize)

      assert refusal.code == :authority_required, "the load-bearing code must survive verbatim"
      assert refusal.class == :refused_authority
      assert refusal.stage == :authorize
      assert refusal.detail == "authority_required"
    end

    test "consequence_unclassified maps to REFUSED_CONSEQUENCE" do
      refusal = Refusal.from_error(%{code: :consequence_unclassified, detail: nil}, :construct)
      assert {refusal.class, refusal.code} == {:refused_consequence, :consequence_unclassified}
    end

    test "the AshA2A.Planning.GoalFacts codes map to REFUSED_STRUCTURE" do
      for code <- [:invalid_goal_facts, :ambiguous_goal_facts_shape, :invalid_request_id] do
        refusal = Refusal.from_error(%{code: code}, :parse)
        assert refusal.code == code
      end

      assert Refusal.from_error(%{code: :invalid_goal_facts}, :parse).class == :refused_structure

      assert Refusal.from_error(%{code: :ambiguous_goal_facts_shape}, :parse).class ==
               :refused_structure

      # request_id smuggling is an identity refusal, not a shape refusal.
      assert Refusal.from_error(%{code: :invalid_request_id}, :parse).class == :refused_identity
    end

    test "the AshA2A.Semantic.Admission codes map across four distinct classes" do
      expected = %{
        semantic_authority_ceiling_violated: :refused_authority,
        semantic_source_mismatch: :refused_identity,
        semantic_goal_missing: :refused_structure,
        semantic_identity_invalid: :refused_identity,
        semantic_fields_missing: :refused_structure,
        ungrounded_assertion: :refused_provenance,
        authority_grant_not_admissible: :refused_authority,
        real_named_entity_not_admissible: :refused_rule,
        semantic_item_invalid: :refused_structure
      }

      for {code, class} <- expected do
        refusal = Refusal.from_error(%{code: code, detail: "d"}, :admit)
        assert {refusal.code, refusal.class} == {code, class}
      end
    end

    test "the AshA2A.SemanticSubject refusal tuple maps to REFUSED_IDENTITY" do
      refusal =
        Refusal.from_error({:error, {:refused_semantic_subject, :graph_digest}}, :identify)

      assert refusal.class == :refused_identity
      assert refusal.code == :refused_semantic_subject
      assert refusal.detail == :graph_digest
    end

    test "a bare {:error, atom} store refusal is lifted" do
      assert Refusal.from_error({:error, :receipt_store_unavailable}, :prepare).class ==
               :blocked_resource

      assert Refusal.from_error({:error, :not_found}, :prepare).class == :blocked_unknown

      assert Refusal.from_error({:error, :command_conflict}, :construct).class ==
               :refused_identity
    end

    test "an already-built refusal passes through unchanged" do
      original = Refusal.new(:refused_plan, :no_hddl_operators, :plan, %{n: 0})
      assert Refusal.from_error(original, :some_other_stage) == original
    end

    test "an unrecognized term becomes BLOCKED_UNKNOWN carrying the original term" do
      refusal = Refusal.from_error({:weird, "shape", 3}, :parse)

      assert refusal.class == :blocked_unknown
      assert refusal.code == :unclassified_error
      assert refusal.detail == {:weird, "shape", 3}
    end
  end

  describe "terminal_standing/1" do
    test "each class family lands in its own terminal standing" do
      assert Refusal.terminal_standing(Refusal.new(:refused_shacl, :c, :s)) == :refused
      assert Refusal.terminal_standing(Refusal.new(:refused_bounds, :c, :s)) == :refused
      assert Refusal.terminal_standing(Refusal.new(:blocked_resource, :c, :s)) == :blocked
      assert Refusal.terminal_standing(Refusal.new(:blocked_unknown, :c, :s)) == :unknown
      assert Refusal.terminal_standing(Refusal.new(:unsupported_profile, :c, :s)) == :unsupported
    end

    test "terminal_standing/1 is total over every class" do
      for class <- Refusal.classes() do
        standing = Refusal.terminal_standing(Refusal.new(class, :c, :s))
        assert standing in [:refused, :blocked, :unknown, :unsupported]
      end
    end
  end

  describe "to_map/1" do
    test "serializes to a JSON-encodable map and survives a real Jason round trip" do
      refusal = Refusal.new(:refused_bounds, :standing_bounds_exceeded, :parsed, %{limit: 10})
      map = Refusal.to_map(refusal)

      assert map["class"] == "refused_bounds"
      assert map["code"] == "standing_bounds_exceeded"
      assert map["stage"] == "parsed"
      assert map["lawful"] == true

      assert {:ok, decoded} = map |> Jason.encode!() |> Jason.decode()
      assert decoded["class"] == "refused_bounds"
      assert decoded["lawful"] == true
    end

    test "a binary detail is preserved verbatim and a nil detail stays nil" do
      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s, "why"))["detail"] == "why"
      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s))["detail"] == nil

      assert Refusal.to_map(Refusal.new(:refused_rule, :c, :s, :atom_detail))["detail"] ==
               "atom_detail"
    end
  end
end
