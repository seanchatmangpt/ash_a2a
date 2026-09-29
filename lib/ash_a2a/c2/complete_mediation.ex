defmodule AshA2A.C2.CompleteMediation do
  alias AshA2A.C2.{Certificate, PolicyEpoch, RevocationEpoch, FencingToken, Principal}
  def admit(e, c, ctx) do
    now = Map.get(ctx, :now_ms, System.system_time(:millisecond))
    with true <- Certificate.bound?(c, e),
         true <- PolicyEpoch.valid?(c, ctx.policy_epoch),
         true <- RevocationEpoch.valid?(c, ctx.revocation_epoch),
         true <- FencingToken.valid?(c, ctx.generation),
         true <- Principal.preserved?(e, c, ctx.principal),
         true <- c.audience == Map.get(ctx, :audience),
         true <- c.not_before_ms <= now and now < c.expires_at_ms,
         true <- is_binary(c.nonce) and byte_size(c.nonce) >= 16,
         do: :ok,
         else: (_ -> {:error, :refused})
  end
end
