defmodule AshA2A.ConsequenceKernel.Refusal do
  @enforce_keys [:code]
  defstruct [:code, :subject, :effect_id, :detail]
  def new(code, attrs \\ []), do: struct!(__MODULE__, Keyword.merge([code: code], attrs))
end
