defmodule AshA2A.ConsequenceKernel.CallEdge do
  @moduledoc false
  @enforce_keys [:caller, :callee, :kind, :subject]
  defstruct [:caller, :callee, :kind, :subject, :source, :line, :dynamic?]

  @type kind :: :kernel | :dispatcher | :ash_effect | :neutral | :dynamic
  @type t :: %__MODULE__{caller: module(), callee: module() | atom(), kind: kind(), subject: binary(), source: binary() | nil, line: pos_integer() | nil, dynamic?: boolean() | nil}

  def new(attrs) when is_map(attrs) do
    with caller when is_atom(caller) <- Map.get(attrs, :caller),
         callee when is_atom(callee) <- Map.get(attrs, :callee),
         kind when kind in [:kernel, :dispatcher, :ash_effect, :neutral, :dynamic] <- Map.get(attrs, :kind),
         subject when is_binary(subject) and byte_size(subject) > 0 <- Map.get(attrs, :subject) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _ -> {:error, :invalid_call_edge}
    end
  end
end
