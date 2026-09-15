defmodule AshA2A.Semantic.AdmissionTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{Admission, IR, Source}

  test "grounds semantic admission in the source and preserves no authority" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    assert {:ok, admitted} = Admission.admit(source, ir)
    assert admitted.standing == :admitted
    assert admitted.authority == :none

    {:ok, ungrounded} = IR.from_map(source.id, proposal("not in the source"))
    assert {:error, %{code: :ungrounded_assertion}} = Admission.admit(source, ungrounded)
  end

  test "fence rejects an IR that is not a fresh unauthoritied candidate" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    already_admitted = %{ir | standing: :admitted}

    assert {:error, %{code: :semantic_authority_ceiling_violated}} =
             Admission.admit(source, already_admitted)

    invalid_authority = %{ir | authority: :invalid}

    assert {:error, %{code: :semantic_authority_ceiling_violated}} =
             Admission.admit(source, invalid_authority)
  end

  test "source_match rejects an IR whose source_id does not match the source" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map("some-other-source-id", proposal("The goal is to lead the people."))

    assert {:error, %{code: :semantic_source_mismatch}} = Admission.admit(source, ir)
  end

  test "require_goal rejects an IR with no goals" do
    source = Source.new("The goal is to lead the people.")
    {:ok, ir} = IR.from_map(source.id, proposal("The goal is to lead the people."))

    goalless = %{ir | goals: []}
    assert {:error, %{code: :semantic_goal_missing}} = Admission.admit(source, goalless)
  end

  test "unique_ids rejects duplicate ids across fields" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    duplicate_goals = [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => text
      },
      %{"id" => "lead", "kind" => "goal", "description" => "lead again", "source_quote" => text}
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", duplicate_goals)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "unique_ids rejects an item missing an id" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    missing_id_goals = [
      %{"kind" => "goal", "description" => "lead the people", "source_quote" => text}
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", missing_id_goals)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "validate_item rejects a relations item missing a required field" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    relation_missing_predicate = [
      %{
        "id" => "rel-1",
        "kind" => "relation",
        "subject" => "lead",
        "object" => "people",
        "source_quote" => text
      }
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("relations", relation_missing_predicate)
      |> then(&IR.from_map(source.id, &1))

    assert {:error,
            %{
              code: :semantic_fields_missing,
              detail: %{field: :relations, missing: ["predicate"]}
            }} =
             Admission.admit(source, ir)
  end

  test "validate_item rejects an authorities item with a non-admissible mode" do
    text = "The goal is to lead the people."
    source = Source.new(text)

    granted_authority = [
      %{
        "id" => "auth-1",
        "kind" => "authority",
        "subject" => "leader",
        "scope" => "people",
        "mode" => "granted",
        "source_quote" => text
      }
    ]

    {:ok, ir} =
      proposal(text)
      |> Map.put("authorities", granted_authority)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :authority_grant_not_admissible}} = Admission.admit(source, ir)
  end

  test "a non-map item is rejected before validate_item ever inspects it" do
    # Real pipeline order (Admission.admit/2) runs unique_ids/1 before
    # validate_items/1, so a non-map item is caught there first (its "id"
    # lookup safely yields nil for a non-map, which then fails the
    # is_binary/1 uniqueness check) -- validate_item/3's own non-map catch-all
    # clause (-> :semantic_item_invalid) can never actually fire for this
    # input shape. This pins that real, observed behavior rather than
    # asserting a code path unique_ids/1 preempts.
    text = "The goal is to lead the people."
    source = Source.new(text)

    {:ok, ir} =
      proposal(text)
      |> Map.put("goals", ["oops"])
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :semantic_identity_invalid}} = Admission.admit(source, ir)
  end

  test "validate_item rejects an entities item whose label carries a real corporate legal-entity suffix, admits an equivalent one without" do
    text = "The board discussed a partnership with Example Corp as a potential vendor."
    source = Source.new(text)

    entity_with_suffix = [
      %{
        "id" => "vendor-1",
        "kind" => "entity",
        "type" => "organization",
        "label" => "Example Corp",
        "source_quote" => "Example Corp"
      }
    ]

    {:ok, ir_with_suffix} =
      proposal(text)
      |> Map.put("entities", entity_with_suffix)
      |> then(&IR.from_map(source.id, &1))

    assert {:error, %{code: :real_named_entity_not_admissible, detail: "vendor-1"}} =
             Admission.admit(source, ir_with_suffix)

    text2 =
      "The board discussed a partnership with a generic external vendor as a potential option."

    source2 = Source.new(text2)

    entity_without_suffix = [
      %{
        "id" => "vendor-2",
        "kind" => "entity",
        "type" => "organization",
        "label" => "a generic external vendor",
        "source_quote" => "a generic external vendor"
      }
    ]

    {:ok, ir_without_suffix} =
      proposal(text2)
      |> Map.put("entities", entity_without_suffix)
      |> then(&IR.from_map(source2.id, &1))

    assert {:ok, %{standing: :admitted}} = Admission.admit(source2, ir_without_suffix)
  end

  defp proposal(quote) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{
        "id" => "lead",
        "kind" => "goal",
        "description" => "lead the people",
        "source_quote" => quote
      }
    ])
  end
end
