defmodule AshA2A.SPIFFE.PDPBinding do
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
