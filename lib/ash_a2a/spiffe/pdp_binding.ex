# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.PDPBinding do
  @moduledoc """
  Binding of a policy decision point to an attested SPIFFE identity, checked by `admit/3`
  against `AshA2A.AuthZEN.Metadata` to prevent PDP mixup and impersonation. A passing
  binding is evidence only; it never substitutes for a C2 certificate.
  """

  alias AshA2A.AuthZEN.Metadata
  alias AshA2A.SPIFFE.AttestedIdentity

  @enforce_keys [:policy_decision_point, :spiffe_id, :trust_domain]
  defstruct @enforce_keys ++ [allow_jwt: false]

  def admit(%Metadata{} = metadata, %AttestedIdentity{} = attested, %__MODULE__{} = binding) do
    with :ok <- Metadata.bind_expected(metadata, binding.policy_decision_point),
         true <- attested.identity.uri == binding.spiffe_id,
         true <- attested.identity.trust_domain == binding.trust_domain,
         true <- binding.allow_jwt or attested.svid_type == :x509 do
      :ok
    else
      {:error, _} = error -> error
      false -> {:error, :spiffe_pdp_binding_mismatch}
    end
  end
end
