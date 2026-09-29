defmodule AshA2A.ConsequenceKernel do
  @moduledoc """
  Canonical C1 consequence boundary.

  The kernel persists an authenticated PreparedEffect before authority
  revalidation or effector invocation, claims exact request/effect identities,
  and records the state transition surrounding DO. Unknown actuator results
  remain replay-blocking evidence and are never promoted to success.
  """

  alias AshA2A.ConsequenceKernel.{
    AuthorityRevalidation,
    PreparedEffectStore,
    UnknownOutcome
  }

  @type result :: {:ok, term()} | {:error, term()} | {:unknown, UnknownOutcome.t()}

  @spec execute(AshA2A.PreparedEffect.t(), keyword()) :: result()
  def execute(prepared, opts) do
    store = Keyword.fetch!(opts, :store)
    owner = Keyword.fetch!(opts, :owner)
    authority = Keyword.fetch!(opts, :authority)
    effector = Keyword.fetch!(opts, :effector)
    principal = Keyword.fetch!(opts, :principal)

    with :ok <- PreparedEffectStore.prepare(store, prepared, opts),
         :ok <- PreparedEffectStore.claim_request(store, prepared.instance.request_id, owner),
         :ok <- PreparedEffectStore.claim_effect(store, prepared.instance.effect_id, owner),
         :ok <- PreparedEffectStore.transition(store, prepared.prepared_digest, :prepared, :claimed),
         :ok <- AuthorityRevalidation.check(authority, prepared, principal),
         :ok <- admit_consequence(prepared),
         :ok <- PreparedEffectStore.transition(store, prepared.prepared_digest, :claimed, :applying) do
      apply_and_record(store, effector, prepared, opts)
    end
  end

  defp admit_consequence(prepared) do
    if AshA2A.ConsequenceClass.admitted?(prepared.consequence_class),
      do: :ok,
      else: {:error, :consequence_unclassified}
  end

  defp apply_and_record(store, effector, prepared, opts) do
    case effector.apply(prepared) do
      {:ok, outcome} ->
        with :ok <- PreparedEffectStore.transition(store, prepared.prepared_digest, :applying, :completed),
             :ok <- PreparedEffectStore.complete(store, prepared.prepared_digest, outcome, opts) do
          {:ok, outcome}
        end

      {:error, reason} ->
        _ = PreparedEffectStore.transition(store, prepared.prepared_digest, :applying, :unknown_outcome)
        {:error, reason}

      {:unknown, reason} ->
        _ = PreparedEffectStore.transition(store, prepared.prepared_digest, :applying, :unknown_outcome)
        {:unknown, UnknownOutcome.new(prepared, reason)}
    end
  rescue
    error ->
      _ = PreparedEffectStore.transition(store, prepared.prepared_digest, :applying, :unknown_outcome)
      {:unknown, UnknownOutcome.new(prepared, {:effector_exception, error})}
  catch
    kind, reason ->
      _ = PreparedEffectStore.transition(store, prepared.prepared_digest, :applying, :unknown_outcome)
      {:unknown, UnknownOutcome.new(prepared, {kind, reason})}
  end
end
