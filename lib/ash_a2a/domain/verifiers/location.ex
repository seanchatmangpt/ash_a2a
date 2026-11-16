defmodule AshA2A.Domain.Verifiers.Location do
  @moduledoc false
  # Attaches a source `location` (the anno of the DSL section named by the
  # error's `path`) to a `Spark.Error.DslError` that was built without one, so
  # every domain verifier refusal points at the declaring source line.

  @doc false
  @spec locate(term(), map()) :: term()
  def locate({:error, %Spark.Error.DslError{location: nil, path: [section | _]} = error}, dsl_state)
      when is_atom(section) do
    {:error, %{error | location: Spark.Dsl.Transformer.get_section_anno(dsl_state, [section])}}
  end

  def locate(other, _dsl_state), do: other
end
