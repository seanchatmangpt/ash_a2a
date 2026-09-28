defmodule AshA2A.GallClosure.EvidenceBindingTest do
 use ExUnit.Case, async: true
 alias AshA2A.GallClosure.EvidenceBinding
 test "bounded admission", do: assert match?({:ok,_}, EvidenceBinding.admit(%{evidence_id: "witness"}))
 test "typed refusal", do: assert EvidenceBinding.admit(%{}) == {:error,:missing_evidence}
end
