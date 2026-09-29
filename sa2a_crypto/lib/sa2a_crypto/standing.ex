defmodule Sa2aCrypto.Standing do
  @moduledoc """
  Cryptographic standing: the ONLY thing this substrate emits.

  `{:valid, %{kid, custodian_id, tier, epoch}}` certifies that a signature
  verified under an active key held by a registry-known custodian. It never
  authorizes an effect ("certify, don't decide"): authorization is decided by
  SA2A/BRCE from standing + policy + authority.
  """

  @type tier :: :i1 | :i2 | :i3 | :i4
  @type valid :: %{
          kid: String.t(),
          custodian_id: String.t(),
          tier: tier(),
          epoch: non_neg_integer()
        }
  @type refusal :: atom()
  @type t :: {:valid, valid()} | {:invalid, refusal()}

  @spec valid?(t()) :: boolean()
  def valid?({:valid, _}), do: true
  def valid?(_), do: false

  @spec refusal(t()) :: refusal() | nil
  def refusal({:invalid, code}), do: code
  def refusal(_), do: nil
end
