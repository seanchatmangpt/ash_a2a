defmodule AshA2A.ConsequenceKernel.Runtime.Pipeline do
  @moduledoc """
  Runtime stages of the C1 consequence boundary: prepare, claim, authority revalidation,
  applying, DO, outcome.

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
         :ok <- ApplyingStage.run(s, p) do
      token = EffectorToken.issue(p, owner)

      p
      |> apply_effect(e, token)
      |> then(&OutcomeStage.persist(s, p, &1))
      |> record_completion(s, p, opts)
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
