defmodule AshA2A.ConsequenceKernel do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.Runtime.Pipeline
  def execute(prepared, opts), do: Pipeline.execute(prepared, opts)
end
