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

  defp proposal(quote) do
    IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{"id" => "lead", "kind" => "goal", "description" => "lead the people", "source_quote" => quote}
    ])
  end
end
