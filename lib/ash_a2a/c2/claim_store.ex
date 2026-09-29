defmodule AshA2A.C2.ClaimStore do
  @callback claim(String.t(), non_neg_integer()) :: :ok | {:error, :already_claimed}
  @callback complete(String.t(), term()) :: :ok | {:error, term()}
end
