defmodule AshA2A.AuthZEN.Absorption do
  @moduledoc """
  End-to-end absorption of an external AuthZEN evaluation by `authorize/5`: binds the
  PDP to an attested SPIFFE identity, projects the effect, evaluates, and admits the
  resulting evidence below SA2A authority through `AshA2A.C2.AuthorityService`. A PDP
  allow never substitutes for a C2 certificate and never confers DO (actuation) authority.
  """

  alias AshA2A.AuthZEN.{AuthorityPolicy, Client, PolicyEvidenceFactory, Projection, Receipt}
  alias AshA2A.C2.{AuthorityRequest, AuthorityService}
  alias AshA2A.SPIFFE.{AttestedIdentity, PDPBinding}

  def authorize(
        %AuthorityRequest{} = request,
        %Client{} = client,
        %AttestedIdentity{} = attested,
        %PDPBinding{} = binding,
        ctx
      )
      when is_map(ctx) do
    with :ok <- PDPBinding.admit(client.metadata, attested, binding),
         {:ok, projected} <-
           Projection.from_effect(request.effect, Map.get(ctx, :authzen_context, %{})),
         {:ok, decision} <- Client.evaluate(client, projected),
         evidence <-
           PolicyEvidenceFactory.from_decision(decision, request.effect, client.metadata),
         {:ok, receipt} <- Receipt.build(projected, evidence),
         authority_ctx <-
           Map.merge(ctx, %{
             authzen_evidence: evidence,
             authzen_expected_pdp: client.metadata.policy_decision_point
           }),
         {:ok, response} <-
           AuthorityService.authorize(AuthorityPolicy, request, authority_ctx) do
      {:ok, response, receipt}
    end
  end
end
