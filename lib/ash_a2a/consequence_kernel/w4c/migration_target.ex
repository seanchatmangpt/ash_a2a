defmodule AshA2A.ConsequenceKernel.W4C.MigrationTarget do
  def for_kind(:observe), do: :dispatch_observe
  def for_kind(_), do: :consequence_kernel
end
