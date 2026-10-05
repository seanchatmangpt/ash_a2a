# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C2.PolicyEvidence do
  @moduledoc """
  Evidence from an external policy decision point (OpenID AuthZEN Authorization
  API 1.0 evaluation), absorbed *below* SA2A authority.

      AuthZEN allow -> PolicyEvidence -> AuthorityService admission
        -> ActuationCertificate -> actuator-local mediation -> DO

  This module is pure and offline: it builds the SARC request for a PDP and
  binds a PDP response to the exact `AuthorityRequest` it answered. It holds no
  key, issues no certificate and calls no actuator, so an `:allow` here is an
  input to `AshA2A.C2.AuthorityService.authorize/3`, never a substitute for it.

  AuthZEN negative knowledge retained: PDP != PEP, the PDP identifier is bound
  (not just the endpoint), metadata is HTTPS-only, unknown metadata keys are
  ignored, and `decision` must be a JSON boolean.
  """

  alias AshA2A.C2.{AuthorityRequest, PreparedEffect}
  alias AshA2A.Identity.Canonical

  @enforce_keys [
    :pdp,
    :decision,
    :effect_digest,
    :principal,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          pdp: binary(),
          decision: :allow | :deny,
          effect_digest: binary(),
          principal: term(),
          policy_epoch: non_neg_integer(),
          revocation_epoch: non_neg_integer(),
          generation: non_neg_integer(),
          digest: binary()
        }

  @doc "AuthZEN SARC (subject/action/resource/context) request for `request`."
  @spec sarc_request(AuthorityRequest.t()) :: {:ok, map()} | {:error, atom()}
  def sarc_request(%AuthorityRequest{effect: %PreparedEffect{} = effect} = r) do
    with {:ok, view} <- PreparedEffect.portable_view(effect) do
      {:ok,
       %{
         "subject" => %{"type" => "principal", "id" => to_string(r.principal)},
         "action" => %{"name" => view["capability"]},
         "resource" => %{
           "type" => "prepared_effect",
           "id" => r.effect_digest,
           "properties" => %{"subject" => view["subject"]}
         },
         "context" => %{
           "effect_digest" => r.effect_digest,
           "policy_epoch" => r.policy_epoch,
           "revocation_epoch" => r.revocation_epoch,
           "generation" => r.generation,
           "audience" => r.audience
         }
       }}
    end
  end

  @doc """
  Bind a PDP response to the request it answers.

  `expected_pdp` is the PDP identifier the PEP was configured with;
  `metadata` is the PDP's discovered metadata (string-keyed). The response is
  refused unless the metadata names `expected_pdp`, and unless `decision` is a
  strict boolean.
  """
  @spec from_response(AuthorityRequest.t(), map(), binary(), map()) ::
          {:ok, t()} | {:error, atom()}
  def from_response(%AuthorityRequest{} = r, response, expected_pdp, metadata)
      when is_map(response) and is_binary(expected_pdp) and is_map(metadata) do
    with :ok <- validate_metadata(metadata, expected_pdp),
         {:ok, decision} <- decision(response),
         body = %{
           "pdp" => expected_pdp,
           "decision" => Atom.to_string(decision),
           "effect_digest" => r.effect_digest,
           "principal" => to_string(r.principal),
           "policy_epoch" => r.policy_epoch,
           "revocation_epoch" => r.revocation_epoch,
           "generation" => r.generation
         },
         {:ok, digest} <- Canonical.digest(body) do
      {:ok,
       %__MODULE__{
         pdp: expected_pdp,
         decision: decision,
         effect_digest: r.effect_digest,
         principal: r.principal,
         policy_epoch: r.policy_epoch,
         revocation_epoch: r.revocation_epoch,
         generation: r.generation,
         digest: digest
       }}
    end
  end

  @doc "Does this evidence answer exactly `request` (digest, principal, fences)?"
  @spec binds?(t(), AuthorityRequest.t()) :: boolean()
  def binds?(%__MODULE__{} = e, %AuthorityRequest{} = r) do
    e.effect_digest == r.effect_digest and e.principal == r.principal and
      e.policy_epoch == r.policy_epoch and e.revocation_epoch == r.revocation_epoch and
      e.generation == r.generation
  end

  @doc "Policy evidence never confers DO authority."
  @spec grants_do_authority?(t()) :: false
  def grants_do_authority?(%__MODULE__{}), do: false

  @doc "PDP metadata check: identifier bound, HTTPS endpoints, unknown keys ignored."
  @spec validate_metadata(map(), binary()) :: :ok | {:error, atom()}
  def validate_metadata(metadata, expected_pdp) do
    cond do
      Map.get(metadata, "policy_decision_point") != expected_pdp -> {:error, :pdp_mismatch}
      not https?(expected_pdp) -> {:error, :pdp_not_https}
      not Enum.all?(endpoints(metadata), &https?/1) -> {:error, :pdp_endpoint_not_https}
      true -> :ok
    end
  end

  defp endpoints(metadata) do
    for {k, v} <- metadata, String.ends_with?(k, "_endpoint"), do: v
  end

  defp https?(url) when is_binary(url), do: String.starts_with?(url, "https://")
  defp https?(_), do: false

  defp decision(%{"decision" => true}), do: {:ok, :allow}
  defp decision(%{"decision" => false}), do: {:ok, :deny}
  defp decision(_), do: {:error, :decision_malformed}
end
