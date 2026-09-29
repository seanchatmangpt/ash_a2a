defmodule AshA2A.C2.RevocationEpoch do
  def valid?(cert, current) when is_integer(current), do: cert.revocation_epoch == current
end
