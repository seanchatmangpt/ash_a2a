defmodule AshA2A.Gall.ProcessIntervention do
  @moduledoc """
  GALL-029 finding admission and GALL-030 bounded intervention.

  Findings remain evidence, never authority. Admission fails closed unless
  exact producer, evidence, semantic subject, horizon, capability, and public
  vocabulary policy is supplied. Only AshA2A.CommandBus.run/4 crosses DO.
  Independent confirmation reuses AshA2A.Postcondition rather than trusting
  the actuator or a self-asserted callback.
  """

  alias AshA2A.{Command, CommandBus, Postcondition, Receipt}

  @finding_classes ~w(conformance prediction attribution postcondition)
  @horizons ~w(FAST MEDIUM SLOW)
  @secret_keys ~w(token password secret credential authorization bearer api_key private_key)

  @spec admit(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit(finding, opts \\ []) when is_map(finding) do
    producer_sha = finding[:producer_sha] || finding["producer_sha"]
    evidence_digest = finding[:evidence_digest] || finding["evidence_digest"]

    semantic_subject_digest =
      finding[:semantic_subject_digest] || finding["semantic_subject_digest"]

    finding_class = finding[:finding_class] || finding["finding_class"]
    horizon = finding[:horizon] || finding["horizon"]
    vocabulary = finding[:vocabulary] || finding["vocabulary"]

    with :ok <- no_secrets(finding),
         :ok <- sha(producer_sha, :producer_sha, 40),
         :ok <- digest(evidence_digest, :evidence_digest),
         :ok <- digest(semantic_subject_digest, :semantic_subject_digest),
         :ok <- member(finding_class, @finding_classes, :finding_class),
         :ok <- member(horizon, @horizons, :horizon),
         {:ok, capability_id} <- capability(finding),
         :ok <-
           allowed(
             producer_sha,
             Keyword.get(opts, :allowed_producers),
             :producer_allowlist_required,
             :stale_or_unadmitted_producer
           ),
         :ok <-
           allowed(
             evidence_digest,
             Keyword.get(opts, :allowed_evidence_digests),
             :evidence_allowlist_required,
             :stale_or_unadmitted_evidence
           ),
         :ok <-
           allowed(
             semantic_subject_digest,
             Keyword.get(opts, :allowed_semantic_subjects),
             :semantic_subject_allowlist_required,
             :stale_or_mismatched_semantic_subject
           ),
         :ok <-
           allowed(
             horizon,
             Keyword.get(opts, :allowed_horizons),
             :horizon_allowlist_required,
             :unadmitted_horizon
           ),
         :ok <-
           allowed(
             capability_id,
             Keyword.get(opts, :allowed_capabilities),
             :capability_allowlist_required,
             :unadmitted_capability
           ),
         :ok <-
           allowed(
             vocabulary,
             Keyword.get(opts, :public_vocabulary),
             :public_vocabulary_required,
             :private_or_unknown_vocabulary
           ) do
      base = %{
        schema: "ash_a2a.gall.process-candidate/v26.9.18",
        finding_digest: canonical_digest(finding),
        producer_sha: producer_sha,
        evidence_digest: evidence_digest,
        semantic_subject_digest: semantic_subject_digest,
        finding_class: finding_class,
        horizon: horizon,
        vocabulary: vocabulary,
        capability_id: capability_id,
        authority: :none
      }

      {:ok, Map.put(base, :candidate_digest, canonical_digest(base))}
    end
  end

  @spec intervene(map(), Command.t(), A2A.Message.t(), module(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def intervene(
        candidate,
        %Command{} = command,
        %A2A.Message{} = message,
        resource_or_domain,
        opts \\ []
      ) do
    postcondition = Keyword.get(opts, :postcondition)

    with :ok <- admitted_candidate(candidate),
         :ok <- command_binding(candidate, command),
         :ok <- require_independent_observer(postcondition),
         {:ok, %Receipt{} = receipt} <- CommandBus.run(command, message, resource_or_domain, opts),
         :ok <- receipt_binding(command, receipt),
         {:ok, observer_receipt} <- independent_confirmation(receipt) do
      {:ok, %{command_receipt: receipt, observer_receipt: observer_receipt}}
    end
  end

  defp require_independent_observer(%Postcondition{}), do: :ok
  defp require_independent_observer(_), do: {:error, :independent_observer_required}

  defp admitted_candidate(
         %{schema: "ash_a2a.gall.process-candidate/v26.9.18", authority: :none} = candidate
       ) do
    expected = candidate |> Map.delete(:candidate_digest) |> canonical_digest()

    if candidate.candidate_digest == expected,
      do: :ok,
      else: {:error, :candidate_digest_mismatch}
  end

  defp admitted_candidate(_), do: {:error, :gall_029_admission_required}

  defp command_binding(candidate, command) do
    bound =
      command.metadata[:gall_029_candidate_digest] ||
        command.metadata["gall_029_candidate_digest"]

    cond do
      command.capability_id != candidate.capability_id -> {:error, :capability_mismatch}
      bound != candidate.candidate_digest -> {:error, :candidate_binding_mismatch}
      true -> :ok
    end
  end

  defp receipt_binding(command, %Receipt{} = receipt) do
    cond do
      receipt.command_id != command.command_id -> {:error, :receipt_command_mismatch}
      receipt.capability_id != command.capability_id -> {:error, :receipt_capability_mismatch}
      receipt.fingerprint != command.fingerprint -> {:error, :receipt_candidate_binding_mismatch}
      true -> :ok
    end
  end

  defp independent_confirmation(%Receipt{
         metadata: %{
           postcondition: %{status: :verified, independent: true} = observation
         }
       }),
       do: {:ok, observation}

  defp independent_confirmation(%Receipt{
         metadata: %{postcondition: %{status: :unverified, reason: reason}}
       }),
       do: {:error, {:independent_observer_unverified, reason}}

  defp independent_confirmation(_), do: {:error, :independent_observer_not_verified}

  defp capability(finding) do
    case finding[:requested_capability_id] || finding["requested_capability_id"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :requested_capability_id}
    end
  end

  defp allowed(_value, nil, required, _mismatch), do: {:error, required}
  defp allowed(_value, [], required, _mismatch), do: {:error, required}

  defp allowed(value, allowed, _required, mismatch) when is_list(allowed) do
    if value in allowed, do: :ok, else: {:error, mismatch}
  end

  defp allowed(_value, _allowed, required, _mismatch), do: {:error, required}

  defp no_secrets(value) when is_map(value) do
    case Enum.find(value, fn {key, nested} ->
           String.downcase(to_string(key)) in @secret_keys or secret_value?(nested)
         end) do
      nil ->
        Enum.reduce_while(value, :ok, fn {_key, nested}, :ok ->
          case no_secrets(nested) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :secret_bearing_finding}
    end
  end

  defp no_secrets(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn nested, :ok ->
      case no_secrets(nested) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp no_secrets(_), do: :ok

  defp secret_value?(value) when is_binary(value),
    do: String.starts_with?(String.downcase(value), "bearer ")

  defp secret_value?(_), do: false

  defp member(value, allowed, field),
    do: if(value in allowed, do: :ok, else: {:error, field})

  defp digest("sha256:" <> hex, _field) when byte_size(hex) == 64, do: :ok
  defp digest(_, field), do: {:error, field}

  defp sha(value, _field, size) when is_binary(value) and byte_size(value) == size, do: :ok
  defp sha(_, field, _size), do: {:error, field}

  defp canonical_digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(canonical(value), [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
      |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
