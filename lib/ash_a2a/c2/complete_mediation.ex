defmodule AshA2A.C2.CompleteMediation do
  alias AshA2A.C2.{Certificate, PolicyEpoch, RevocationEpoch, FencingToken, Principal}

  def admit(e, c, ctx) do
    now = now_ms(ctx)

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

  # Canonical time source: `:now_ms` (milliseconds) if given, else the verifier's `:now` (unix
  # seconds, the same value handed to Sa2aCrypto), else the system clock.
  defp now_ms(%{now_ms: ms}) when is_integer(ms), do: ms
  defp now_ms(%{now: s}) when is_integer(s), do: s * 1000
  defp now_ms(_), do: System.system_time(:millisecond)
end
