# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.Pipeline do
  @moduledoc """
  Runtime stages of the C1 consequence boundary, the single DO path: prepare, claim, authority
  revalidation, class admission, W5 independent effect claim, applying, DO, outcome.

  The W5 `ClaimProtocol` is mandatory (fail closed): `opts` must carry `:claim_store`,
  `:claim_store_handle` and `:claim_key`, else the run is refused with
  `:independent_effect_claim_store_required` before the apply boundary. The claim moves
  claimed -> doing before DO and to completed / unknown_outcome after it.

  When `opts` carries `:key_provider`, the prepared record is sealed with
  `PreparedEffectStore.AuthenticatedRecord` (MAC under the provider's key) before anything else
  happens, a duplicate prepare is admitted only if the stored record verifies, and a completed
  outcome is recorded with `PreparedEffectStore.complete/4`. An effector that raises or throws
  after the applying boundary is an unknown outcome (replay-blocking), never a success and never
  a retry.
  """
  alias AshA2A.ConsequenceKernel.{PreparedEffectStore, UnknownOutcome}

  alias AshA2A.ConsequenceKernel.Runtime.{
    StoreHandle,
    PrepareStage,
    ClaimStage,
    AuthorityStage,
    ApplyingStage,
    OutcomeStage,
    PreparedDigest,
    EffectorToken
  }

  alias AshA2A.ConsequenceKernel.W5.ClaimProtocol

  def execute(p, opts) do
    store = Keyword.fetch!(opts, :store)
    handle = Keyword.fetch!(opts, :store_handle)
    s = StoreHandle.new(store, handle)
    owner = Keyword.fetch!(opts, :owner)
    a = Keyword.fetch!(opts, :authority)
    e = Keyword.fetch!(opts, :effector)

    with :ok <- prepare(s, {store, handle}, p, opts),
         :ok <- ClaimStage.run(s, p, owner),
         :ok <- AuthorityStage.run(a, Keyword.fetch!(opts, :principal), p),
         true <- AshA2A.ConsequenceClass.admitted?(p.consequence_class),
         {:ok, ctx} <- ClaimProtocol.claim(p, owner, opts),
         :ok <- ClaimProtocol.begin_do(ctx),
         :ok <- ApplyingStage.run(s, p) do
      token = EffectorToken.issue(p, owner)

      outcome =
        p
        |> apply_effect(e, token)
        |> then(&OutcomeStage.persist(s, p, &1))
        |> record_completion(s, p, opts)

      _ = ClaimProtocol.record_outcome(ctx, outcome)
      outcome
    else
      false -> {:error, :consequence_unclassified}
      {:error, _} = x -> x
      {:unknown, _} = x -> x
    end
  end

  defp prepare(s, _store, p, opts) do
    if Keyword.has_key?(opts, :key_provider),
      do: PreparedEffectStore.prepare({s.module, s.server}, p, opts),
      else: PrepareStage.run(s, p)
  end

  # An exception or throw from the effector happens after the applying boundary: the effect may
  # or may not have happened, so it is an unknown outcome carrying the reason as evidence.
  defp apply_effect(p, e, token) do
    if function_exported?(e, :apply, 2), do: e.apply(p, token), else: e.apply(p)
  rescue
    error -> {:unknown, UnknownOutcome.new(p, {:effector_exception, error})}
  catch
    kind, reason -> {:unknown, UnknownOutcome.new(p, {kind, reason})}
  end

  defp record_completion({:ok, outcome} = ok, s, p, opts) do
    if Keyword.has_key?(opts, :key_provider) do
      with {:ok, digest} <- PreparedDigest.fetch(p),
           :ok <- PreparedEffectStore.complete({s.module, s.server}, digest, outcome, opts),
           do: ok
    else
      ok
    end
  end

  defp record_completion(other, _s, _p, _opts), do: other
end
