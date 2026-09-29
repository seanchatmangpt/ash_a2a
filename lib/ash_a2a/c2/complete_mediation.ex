defmodule AshA2A.C2.CompleteMediation do
  alias AshA2A.C2.{Certificate, PolicyEpoch, RevocationEpoch, FencingToken, Principal}

  def admit(e, c, ctx) do
    with true <- Certificate.bound?(c, e),
         true <- PolicyEpoch.valid?(c, ctx.policy_epoch),
         true <- RevocationEpoch.valid?(c, ctx.revocation_epoch),
         true <- FencingToken.valid?(c, ctx.generation),
         true <- Principal.preserved?(e, c, ctx.principal),
         do: :ok,
         else: (_ -> {:error, :refused})
  end
end
