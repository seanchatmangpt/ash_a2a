defmodule AshA2A.Semantic.Schema do
  @moduledoc "Structured-output contract for semantic extraction."

  alias AshA2A.Semantic.IR

  def extraction do
    collections =
      Map.new(IR.fields(), fn field ->
        {Atom.to_string(field), %{"type" => "array", "items" => assertion()}}
      end)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Map.put(collections, "authority", %{"type" => "string", "enum" => ["none"]}),
      "required" => ["authority" | Enum.map(IR.fields(), &Atom.to_string/1)]
    }
  end

  defp assertion do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "id" => %{"type" => "string"},
        "kind" => %{"type" => "string"},
        "label" => %{"type" => "string"},
        "type" => %{"type" => "string"},
        "subject" => %{"type" => "string"},
        "predicate" => %{"type" => "string"},
        "object" => %{"type" => "string"},
        "description" => %{"type" => "string"},
        "scope" => %{"type" => "string"},
        "mode" => %{"type" => "string", "enum" => ["described", "denied", "unknown"]},
        "source_quote" => %{"type" => "string"}
      },
      "required" => ["id", "kind", "source_quote"]
    }
  end
end
