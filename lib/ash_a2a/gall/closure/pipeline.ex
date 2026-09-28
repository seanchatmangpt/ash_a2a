defmodule AshA2A.Gall.Closure.Pipeline do
  @moduledoc "Dependency-closed admission/preflight/consumer pipeline layered on the canonical GALL-029/030 runtime."

  alias AshA2A.Gall.Closure.{
    BudgetPolicy,
    CapabilityPolicy,
    CommandBinding,
    EvidencePolicy,
    ExactSubject,
    IdempotencyPolicy,
    PostconditionPolicy,
    ProducerPolicy,
    Provenance,
    ScopePolicy,
    SemanticSubjectPolicy,
    VocabularyPolicy
  }

  def admit(candidate, policy) when is_map(candidate) and is_map(policy) do
    with {:ok, exact} <- ExactSubject.admit(candidate),
         {:ok, candidate} <- ProducerPolicy.admit(candidate, policy[:allowed_producers] || %{}),
         {:ok, candidate} <-
           EvidencePolicy.admit(candidate, policy[:allowed_evidence_digests] || []),
         {:ok, candidate} <-
           SemanticSubjectPolicy.admit(candidate, policy[:allowed_semantic_subjects] || []),
         {:ok, candidate} <- VocabularyPolicy.admit(candidate, policy[:public_vocabularies] || []),
         {:ok, candidate} <-
           CapabilityPolicy.admit(candidate, policy[:allowed_capabilities] || []) do
      {:ok,
       %{
         candidate: candidate,
         exact_subject: exact,
         provenance: Provenance.build(candidate, policy[:task_id])
       }}
    end
  end

  def admit(_, _), do: {:error, {:refused_gall, :pipeline, :invalid_admission_request}}

  def preflight(%{candidate: candidate} = admitted, command, opts)
      when is_map(command) and is_map(opts) do
    scope = opts[:scope] || %{}
    budget = opts[:max_consequences]
    expected = opts[:expected_postcondition] || %{}

    with {:ok, _} <- CommandBinding.admit(candidate, command),
         {:ok, _} <- ScopePolicy.admit(scope, command),
         {:ok, _} <- BudgetPolicy.admit(budget),
         {:ok, _} <- IdempotencyPolicy.admit(command, candidate),
         {:ok, postcondition} <- PostconditionPolicy.bind(expected) do
      {:ok,
       admitted
       |> Map.put(:command, command)
       |> Map.put(:scope, scope)
       |> Map.put(:budget, 1)
       |> Map.put(:postcondition, postcondition)}
    end
  end

  def preflight(_, _, _), do: {:error, {:refused_gall, :pipeline, :invalid_preflight_request}}
end
