defmodule AshA2A.ArchitectureEnvelope do
  @moduledoc """
  Portable ABB/SBB interchange envelope for SA2A.

  The envelope preserves exact architecture identity across provider and
  transport substitutions. It can carry OBSERVE/PROPOSE/SELECT intent, but
  cannot confer qualification or consequential authority.
  """

  @operations [:observe, :propose, :select]
  @levels %{none: 0, observe: 1, select: 2, construct: 3, do: 4}

  @required [:abb_digest, :contract_digest, :candidate_digest, :exact_subject_digest]

  @spec build(map(), keyword()) :: {:ok, map()} | {:error, {:refused, term()}}
  def build(subject, opts \\ []) when is_map(subject) do
    operation = Keyword.get(opts, :operation, :observe)
    authority = Keyword.get(opts, :authority, :none)
    qualification = Keyword.get(opts, :qualification)
    provider = Keyword.get(opts, :provider)
    transport = Keyword.get(opts, :transport)

    with :ok <- require_fields(subject),
         true <- operation in @operations || {:error, {:refused, :unsupported_operation}},
         :ok <- require_authority(authority),
         :ok <- verify_qualification(subject, qualification) do
      semantic_identity =
        digest({
          subject.abb_digest,
          subject.contract_digest,
          subject.candidate_digest,
          subject.exact_subject_digest
        })

      body = %{
        schema: "ash-a2a.ea-envelope.v1",
        semantic_identity: semantic_identity,
        abb_digest: subject.abb_digest,
        contract_digest: subject.contract_digest,
        candidate_digest: subject.candidate_digest,
        exact_subject_digest: subject.exact_subject_digest,
        qualification_digest: qualification_digest(qualification),
        qualification_standing: qualification_standing(qualification),
        operation: operation,
        authority_ceiling: :select,
        execution_authority: :none,
        provider: provider,
        transport: transport
      }

      {:ok, Map.put(body, :envelope_digest, digest(body))}
    end
  end

  @spec semantic_identity(map()) :: String.t()
  def semantic_identity(envelope), do: envelope.semantic_identity

  defp require_fields(subject) do
    case Enum.find(@required, fn field ->
           value = Map.get(subject, field)
           is_nil(value) or value == ""
         end) do
      nil -> :ok
      field -> {:error, {:refused, {:missing_exact_subject, field}}}
    end
  end

  defp require_authority(authority) do
    case Map.fetch(@levels, authority) do
      :error ->
        {:error, {:refused, :invalid_authority}}

      {:ok, level} when level <= 2 ->
        :ok

      {:ok, _level} ->
        {:error, {:refused, :authority_laundering}}
    end
  end

  defp verify_qualification(_subject, nil), do: :ok

  defp verify_qualification(subject, qualification) when is_map(qualification) do
    cond do
      Map.get(qualification, :standing) != :qualified ->
        {:error, {:refused, :forged_qualification}}

      Map.get(qualification, :candidate_digest) != subject.candidate_digest ->
        {:error, {:refused, :stale_candidate}}

      Map.get(qualification, :contract_digest) != subject.contract_digest ->
        {:error, {:refused, :stale_contract}}

      Map.get(qualification, :exact_subject_digest) != subject.exact_subject_digest ->
        {:error, {:refused, :stale_subject}}

      not is_binary(Map.get(qualification, :qualification_digest)) ->
        {:error, {:refused, :forged_qualification}}

      true ->
        :ok
    end
  end

  defp qualification_digest(nil), do: nil
  defp qualification_digest(q), do: q.qualification_digest
  defp qualification_standing(nil), do: :candidate
  defp qualification_standing(q), do: q.standing

  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end
end
