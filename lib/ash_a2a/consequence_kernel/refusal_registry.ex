defmodule AshA2A.ConsequenceKernel.RefusalRegistry do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.RefusalCodes
  def known?(c), do: RefusalCodes.known?(c)
  def codes, do: RefusalCodes.codes()
  def classify(c), do: RefusalCodes.classify(c)
end
