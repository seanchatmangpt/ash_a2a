defmodule AshA2A.Test.AuthorityGrantCase do
  @moduledoc """
  Shared real-broker bootstrap for tests that dispatch a `:change` or
  `:external_do` skill through the real `AshA2A.Agent` path as an
  authenticated caller.

  Since `AshA2A.Authority.Grant`'s fail-closed `:broker` default landed,
  authentication alone no longer confers authority for a capability
  (RFC-SA2A-001 S29) -- a real, standing capability grant must exist. This
  module starts a REAL `AshA2A.Authority.Broker.InMemory` process (a real
  `GenServer` holding real issued/revoked state, not a stub of one), points
  `:ash_a2a`'s `:authority_broker` at it for the duration of the test, and
  issues the real grants the test's own dispatches need through the real
  `AshA2A.Authority.Grant.grant/3` seam. Nothing here is a mock, a bypass, or
  a relaxation of the policy under test: it is the same real grant path a
  real deployment uses.

  Grants go into the one run-wide broker `test/test_helper.exs` starts and
  `config/test.exs` configures, and no application environment is mutated at
  runtime -- so this is safe to call from an `async: true` module. Grants are
  keyed on `AshA2A.Authority.grant_token_id/2`, i.e. on `(principal,
  capability_id)`, so two modules granting different principals cannot
  collide. A test that needs isolated revocation state should start its own
  uniquely-named broker instead and be `async: false`.
  """

  alias AshA2A.{Authority, Identity}

  @doc """
  Issues one real capability grant per `{principal, capability_id}` pair in
  `grants`, through the real `AshA2A.Authority.Grant.grant/3` seam.

  `grants` is a list of `{principal, capability_ids}` tuples, where
  `principal` is the SAME term the test's verified `auth_identity` carries
  (any term -- `AshA2A.Identity.principal/1` normalizes it identically on
  both sides) and `capability_ids` is a list of capability id strings.

      setup do
        AshA2A.Test.AuthorityGrantCase.grant!([{"user-1", ["create_item", "update_item"]}])
        :ok
      end

  Re-granting an already-granted pair is a no-op rather than an error: the
  broker legitimately refuses a second `issue/3` under the same grant token
  id with `:token_id_taken`, which means the grant this call wanted already
  stands. The post-condition asserted here is the real one -- that the grant
  is genuinely readable back from the broker afterwards
  (`AshA2A.Authority.Grant.granted?/3`), not merely that a call returned
  `:ok`.
  """
  @spec grant!([{term(), [String.t()]}]) :: :ok
  def grant!(grants) when is_list(grants) do
    for {principal, capability_ids} <- grants, capability_id <- capability_ids do
      subject = Identity.principal(principal)

      case Authority.Grant.grant(subject, capability_id) do
        {:ok, %Authority{}} -> :ok
        {:error, %{reason: :token_id_taken}} -> :ok
      end

      true = Authority.Grant.granted?(subject, capability_id)
    end

    :ok
  end
end
