defmodule AshA2A.Semantic.IR do
  @moduledoc "Candidate semantic state extracted from one source."

  @fields ~w(entities relations events goals constraints capabilities authorities observations uncertainties exclusions temporal_relations causal_hypotheses unresolved)a
  @enforce_keys [:source_id]
  defstruct [:source_id, standing: :candidate, authority: :none] ++ Enum.map(@fields, &{&1, []})

  @type t :: %__MODULE__{}

  def from_map(source_id, proposed) when is_binary(source_id) and is_map(proposed) do
    ir =
      Enum.reduce(@fields, %__MODULE__{source_id: source_id}, fn field, acc ->
        values = Map.get(proposed, Atom.to_string(field), [])
        Map.put(acc, field, if(is_list(values), do: values, else: []))
      end)

    authority = if Map.get(proposed, "authority") == "none", do: :none, else: :invalid
    {:ok, %{ir | authority: authority}}
  end

  def from_map(_source_id, value), do: {:error, %{code: :invalid_semantic_ir, detail: value}}

  def fields, do: @fields

  def items(%__MODULE__{} = ir) do
    Enum.flat_map(@fields, fn field -> Enum.map(Map.fetch!(ir, field), &{field, &1}) end)
  end
end
