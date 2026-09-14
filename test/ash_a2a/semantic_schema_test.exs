defmodule AshA2A.Semantic.SchemaTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{IR, Schema}

  describe "extraction/0" do
    setup do
      {:ok, schema: Schema.extraction()}
    end

    test "additionalProperties is false", %{schema: schema} do
      assert schema["additionalProperties"] == false
    end

    test "properties keys are exactly IR fields plus authority", %{schema: schema} do
      expected = MapSet.new(Enum.map(IR.fields(), &Atom.to_string/1) ++ ["authority"])
      actual = schema["properties"] |> Map.keys() |> MapSet.new()
      assert actual == expected
    end

    test "required is exactly IR fields plus authority", %{schema: schema} do
      expected = MapSet.new(Enum.map(IR.fields(), &Atom.to_string/1) ++ ["authority"])
      actual = MapSet.new(schema["required"])
      assert actual == expected
    end

    test "authority property is a string enum of none", %{schema: schema} do
      assert schema["properties"]["authority"] == %{
               "type" => "string",
               "enum" => ["none"]
             }
    end

    test "each IR field property is an array of the shared assertion schema", %{schema: schema} do
      field_strings = Enum.map(IR.fields(), &Atom.to_string/1)

      assertion_schemas =
        Enum.map(field_strings, fn field ->
          entry = schema["properties"][field]
          assert entry["type"] == "array"
          assert is_map(entry["items"])
          entry["items"]
        end)

      # every field's nested assertion schema is identical
      assert Enum.uniq(assertion_schemas) |> length() == 1

      Enum.each(assertion_schemas, fn item_schema ->
        assert %{"type" => "array", "items" => ^item_schema} =
                 schema["properties"][hd(field_strings)]
      end)
    end

    test "shared assertion schema has the load-bearing mode enum and required fields", %{
      schema: schema
    } do
      assertion = schema["properties"]["goals"]["items"]

      assert assertion["properties"]["mode"]["enum"] == ["described", "denied", "unknown"]
      assert assertion["required"] == ["id", "kind", "source_quote"]
    end

    test "assertion schema is identical regardless of which field it is read from", %{
      schema: schema
    } do
      for field <- Enum.map(IR.fields(), &Atom.to_string/1) do
        assert schema["properties"][field]["items"] == schema["properties"]["goals"]["items"]
      end
    end
  end
end
