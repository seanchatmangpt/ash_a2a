defmodule AshA2A.ConsequenceKernel.W5.ClaimIdentity do
  def bind(r, e, p, s) when is_binary(r) and is_binary(e) and is_binary(p) and is_binary(s),
    do: {:ok, :crypto.hash(:sha256, Enum.join([r, e, p, s], "\0")) |> Base.encode16(case: :lower)}

  def bind(_, _, _, _), do: {:error, :invalid_claim_identity}
end
