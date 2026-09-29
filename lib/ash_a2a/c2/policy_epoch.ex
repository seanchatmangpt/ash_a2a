defmodule AshA2A.C2.PolicyEpoch do
  def valid?(cert, current) when is_integer(current), do: cert.policy_epoch == current
end
