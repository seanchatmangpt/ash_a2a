defmodule AshA2A.ConsequenceKernel.W4.ResolvedEffect do
  @moduledoc false
  @enforce_keys [:request, :route]
  defstruct [:request, :route, :exact_subject, :prepared_digest]
  @type t :: %__MODULE__{}
end
