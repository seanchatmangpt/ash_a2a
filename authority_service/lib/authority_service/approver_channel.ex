defmodule AuthorityService.ApproverChannel do
  @moduledoc """
  Pluggable channel to registered human signers (the sa2a-approver wire is a later lane).

  `solicit/3` asks `approver_id` (a custodian id from the policy) to sign the presented
  effect. The response is data: the service re-verifies it exactly like an attached
  approval; a channel never grants standing.
  """
  @type request :: %{
          effect: binary(),
          effect_digest: String.t(),
          principal: String.t(),
          policy_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          audience: String.t()
        }
  @callback solicit(state :: term(), approver_id :: String.t(), request()) ::
              {:ok, %{envelope: Sa2aCrypto.Envelope.t(), message: binary()}} | {:error, atom()}
end
