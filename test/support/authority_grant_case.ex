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

  ## SA2A-AUTH-017 (RFC-SA2A-002 S66, capability substitution)

  `AshA2A.Agent.build_command/4` now resolves the dispatched skill's
  CANONICAL capability id (`AshA2A.Info.skill/2`,
  `"\#{inspect(resource)}.\#{action}"`) before calling
  `AshA2A.Authority.Grant.authorize/3` -- so a grant issued under a bare
  wire selector ("create_item") no longer matches what the real dispatch
  path looks up. `grant!/1` therefore takes the resource/domain each
  capability id selector belongs to and resolves it the SAME way before
  issuing, so a grant issued here is the grant the real dispatch path finds.
  """

  alias AshA2A.{Authority, Identity}

  @doc """
  Issues one real capability grant per `{principal, resource_or_domain,
  capability_selectors}` triple in `grants`, through the real
  `AshA2A.Authority.Grant.grant/3` seam.

  `principal` is the SAME term the test's verified `auth_identity` carries
  (any term -- `AshA2A.Identity.principal/1` normalizes it identically on
  both sides). `resource_or_domain` is the real Ash resource/domain module
  each selector in `capability_selectors` is resolved against via
  `AshA2A.Info.skill/2` into its canonical capability id -- the exact id
  `AshA2A.Agent.build_command/4` resolves on the real dispatch path -- before
  the grant is issued. A principal with capabilities spanning more than one
  resource needs one triple per resource.

      setup do
        AshA2A.Test.AuthorityGrantCase.grant!([
          {"user-1", AshA2A.Test.Fixture.Item, ["create_item", "update_item"]}
        ])

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
  @spec grant!([{term(), module(), [String.t()]}]) :: :ok
  def grant!(grants) when is_list(grants) do
    for {principal, resource_or_domain, capability_selectors} <- grants,
        selector <- capability_selectors do
      subject = Identity.principal(principal)
      capability_id = capability_id!(resource_or_domain, selector)

      case Authority.Grant.grant(subject, capability_id) do
        {:ok, %Authority{}} -> :ok
        {:error, %{reason: :token_id_taken}} -> :ok
      end

      true = Authority.Grant.granted?(subject, capability_id)
    end

    :ok
  end

  defp capability_id!(resource_or_domain, selector) do
    case AshA2A.Info.skill(resource_or_domain, selector) do
      {:ok, %{id: id}} ->
        id

      {:error, :skill_not_found} ->
        raise ArgumentError,
              "AshA2A.Test.AuthorityGrantCase.grant!/1: #{inspect(resource_or_domain)} has " <>
                "no skill matching #{inspect(selector)}"
    end
  end
end
