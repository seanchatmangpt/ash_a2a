defmodule AshA2A.Gall.ProcessIntervention do
  @moduledoc """
  GALL-029 finding admission and GALL-030 bounded intervention.

  Findings remain evidence, never authority. Admission fails closed unless
  exact producer (repository-pinned when a `%{repo => sha}` map is supplied),
  evidence, semantic subject, horizon, capability, and public vocabulary
  policy is supplied. SHAs and digests must be lowercase hex. The capability
  is derived only from an explicit `:admission_rules` map keyed
  `{vocabulary, finding_type, candidate_class}`; a finding-supplied
  `requested_capability_id` is never authority and is refused with
  `:capability_mismatch` when it disagrees with the rule.

  An admitted candidate carries `evidence_ceiling: "ADMIT_ONLY"`. Crossing DO
  additionally requires an admitting `AshA2A.Authority`, and a one-DO policy
  budget: a non-empty `:scope` whose `input_digest` equals the canonical
  digest of the command input, `max_consequences: 1`, a non-empty
  `idempotency_key` in command metadata, and a non-empty
  `:expected_postcondition` equal to the declared `AshA2A.Postcondition`
  expectation. Only AshA2A.CommandBus.run/4 crosses DO. Independent
  confirmation reuses AshA2A.Postcondition rather than trusting the actuator
  or a self-asserted callback; a verified result carries
  `evidence_ceiling: "AUTHORIZED_DO"` and `postcondition_standing: "VERIFIED"`.
  """

  alias AshA2A.{Authority, Command, CommandBus, Postcondition, Receipt}

  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

  @finding_classes ~w(conformance prediction attribution postcondition)
  @horizons ~w(FAST MEDIUM SLOW)
  @secret_keys ~w(token password secret credential authorization bearer api_key private_key)

  @gall_opts [:scope, :max_consequences, :expected_postcondition]

  @spec admit(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit(finding, opts \\ []) when is_map(finding) do
    producer_repository = field(finding, :producer_repository)
    producer_sha = field(finding, :producer_sha)
    evidence_digest = field(finding, :evidence_digest)
    semantic_subject_digest = field(finding, :semantic_subject_digest)
    finding_class = field(finding, :finding_class)
    finding_type = field(finding, :finding_type)
    candidate_class = field(finding, :candidate_class)
    horizon = field(finding, :horizon)
    vocabulary = field(finding, :vocabulary)

    with :ok <- no_secrets(finding),
         :ok <- repository(producer_repository),
         :ok <- sha(producer_sha, :producer_sha, 40),
         :ok <- digest(evidence_digest, :evidence_digest),
         :ok <- digest(semantic_subject_digest, :semantic_subject_digest),
         :ok <- member(finding_class, @finding_classes, :finding_class),
         :ok <- member(horizon, @horizons, :horizon),
         :ok <-
           producer_allowed(
             producer_repository,
             producer_sha,
             Keyword.get(opts, :allowed_producers)
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
             vocabulary,
             Keyword.get(opts, :public_vocabulary),
             :public_vocabulary_required,
             :private_or_unknown_vocabulary
           ),
         {:ok, capability_id} <- capability(finding, Keyword.get(opts, :admission_rules)),
         :ok <-
           allowed(
             capability_id,
             Keyword.get(opts, :allowed_capabilities),
             :capability_allowlist_required,
             :unadmitted_capability
           ) do
      base = %{
        schema: "ash_a2a.gall.process-candidate/v26.9.18",
        finding_digest: canonical_digest(finding),
        producer_repository: producer_repository,
        producer_sha: producer_sha,
        evidence_digest: evidence_digest,
        semantic_subject_digest: semantic_subject_digest,
        finding_class: finding_class,
        finding_type: finding_type,
        candidate_class: candidate_class,
        horizon: horizon,
        vocabulary: vocabulary,
        capability_id: capability_id,
        evidence_ceiling: "ADMIT_ONLY",
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
    bus_opts = Keyword.drop(opts, @gall_opts)

    with :ok <- admitted_candidate(candidate),
         :ok <- command_binding(candidate, command),
         :ok <- authority_binding(command),
         {:ok, expected_postcondition_digest} <- intervention_constraints(command, opts),
         :ok <- require_independent_observer(postcondition),
         :ok <- postcondition_binding(postcondition, expected_postcondition_digest),
         {:ok, %Receipt{} = receipt} <-
           CommandBus.run(command, message, resource_or_domain, bus_opts),
         :ok <- receipt_binding(command, receipt),
         {:ok, observer_receipt} <- independent_confirmation(receipt),
         :ok <- observation_binding(postcondition, observer_receipt) do
      {:ok,
       %{
         command_receipt: receipt,
         observer_receipt: observer_receipt,
         evidence_ceiling: "AUTHORIZED_DO",
         postcondition_standing: "VERIFIED",
         expected_postcondition_digest: expected_postcondition_digest
       }}
    end
  end

  defp require_independent_observer(%Postcondition{}), do: :ok
  defp require_independent_observer(_), do: {:error, :independent_observer_required}

  # The scoped expected postcondition must be exactly what the independent
  # observer is declared to verify; otherwise the observer could confirm a
  # different subject than the one the budget authorized.
  defp postcondition_binding(%Postcondition{expect: expect}, expected_postcondition_digest) do
    if canonical_digest(expect) == expected_postcondition_digest,
      do: :ok,
      else: {:error, :observer_postcondition_subject_mismatch}
  end

  defp observation_binding(%Postcondition{id: id}, observation) do
    case observation[:postcondition_id] || observation["postcondition_id"] do
      nil -> :ok
      ^id -> :ok
      _ -> {:error, :observer_postcondition_subject_mismatch}
    end
  end

  defp admitted_candidate(
         %{
           schema: "ash_a2a.gall.process-candidate/v26.9.18",
           authority: :none,
           evidence_ceiling: "ADMIT_ONLY"
         } = candidate
       ) do
    expected = candidate |> Map.delete(:candidate_digest) |> canonical_digest()

    if candidate.candidate_digest == expected,
      do: :ok,
      else: {:error, :candidate_digest_mismatch}
  end

  defp admitted_candidate(_), do: {:error, :gall_029_admission_required}

  defp command_binding(candidate, command) do
    bound = Command.candidate_digest(command)

    cond do
      command.capability_id != candidate.capability_id -> {:error, :capability_mismatch}
      bound != candidate.candidate_digest -> {:error, :candidate_binding_mismatch}
      true -> :ok
    end
  end

  defp authority_binding(%Command{authority: %Authority{} = authority} = command) do
    if Authority.admits?(authority, %{
         principal_id: command.principal_id,
         capability_id: command.capability_id
       }),
       do: :ok,
       else: {:error, :authority_mismatch}
  end

  defp authority_binding(%Command{authority: nil}), do: {:error, :authority_required}
  defp authority_binding(_), do: {:error, :authority_mismatch}

  defp intervention_constraints(command, opts) do
    scope = Keyword.get(opts, :scope)
    max_consequences = Keyword.get(opts, :max_consequences)
    expected = Keyword.get(opts, :expected_postcondition)
    idempotency_key = field(command.metadata || %{}, :idempotency_key)

    cond do
      not is_map(scope) or map_size(scope) == 0 ->
        {:error, :intervention_scope_required}

      max_consequences != 1 ->
        {:error, :intervention_budget_must_be_one}

      field(scope, :input_digest) != canonical_digest(command.input) ->
        {:error, :intervention_scope_input_mismatch}

      not is_binary(idempotency_key) or idempotency_key == "" ->
        {:error, :intervention_idempotency_required}

      not is_map(expected) or map_size(expected) == 0 ->
        {:error, :expected_postcondition_required}

      true ->
        {:ok, canonical_digest(expected)}
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

  # Capability is derived from an explicit semantic admission rule, never
  # taken from the finding. A finding-supplied requested_capability_id that
  # disagrees with the rule is refused rather than silently ignored.
  defp capability(finding, rules) when is_map(rules) do
    key =
      {field(finding, :vocabulary), field(finding, :finding_type),
       field(finding, :candidate_class)}

    requested = field(finding, :requested_capability_id)

    case Map.get(rules, key) do
      value when is_binary(value) and value != "" ->
        if is_nil(requested) or requested == value,
          do: {:ok, value},
          else: {:error, :capability_mismatch}

      nil ->
        {:error, :unsupported_process_finding_rule}

      _ ->
        {:error, :invalid_process_finding_rule}
    end
  end

  defp capability(_finding, _rules), do: {:error, :invalid_process_finding_rules}

  # List form: bare SHA membership. Map form: the SHA is pinned to its
  # producer repository.
  defp producer_allowed(repository, producer_sha, allowed)
       when is_map(allowed) and map_size(allowed) > 0 do
    if Map.get(allowed, repository) == producer_sha,
      do: :ok,
      else: {:error, :stale_or_unadmitted_producer}
  end

  defp producer_allowed(_repository, producer_sha, allowed) when is_list(allowed),
    do:
      allowed(
        producer_sha,
        allowed,
        :producer_allowlist_required,
        :stale_or_unadmitted_producer
      )

  defp producer_allowed(_repository, _producer_sha, _allowed),
    do: {:error, :producer_allowlist_required}

  defp allowed(_value, nil, required, _mismatch), do: {:error, required}
  defp allowed(_value, [], required, _mismatch), do: {:error, required}

  defp allowed(value, allowed, _required, mismatch) when is_list(allowed) do
    if value in allowed, do: :ok, else: {:error, mismatch}
  end

  defp allowed(_value, _allowed, required, _mismatch), do: {:error, required}

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

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

  defp repository(value) when is_binary(value),
    do: if(Regex.match?(@repository, value), do: :ok, else: {:error, :producer_repository})

  defp repository(_), do: {:error, :producer_repository}

  defp digest(value, field) when is_binary(value),
    do: if(Regex.match?(@digest, value), do: :ok, else: {:error, field})

  defp digest(_, field), do: {:error, field}

  defp sha(value, field, 40) when is_binary(value),
    do: if(Regex.match?(@sha, value), do: :ok, else: {:error, field})

  defp sha(_, field, _size), do: {:error, field}

  @doc false
  @spec canonical_digest(term()) :: String.t()
  def canonical_digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(canonical(value), [:deterministic]))
       |> Base.encode16(case: :lower))
  end

  defp canonical(value) when is_map(value) and not is_struct(value),
    do:
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
      |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
