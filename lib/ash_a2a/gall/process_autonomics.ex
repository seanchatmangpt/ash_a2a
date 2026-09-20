defmodule AshA2A.Gall.ProcessFinding do
  @moduledoc """
  GALL-029 process-finding admission.

  This module admits an evidence-bound process finding as a CANDIDATE only.
  It does not manufacture authority, mutate normative process law, or perform
  a consequence. The producer repository/SHA, producer receipt, evidence,
  semantic subject and process subject remain distinct identities.
  """

  @schema "gall.process-finding/v26.9.18"
  @receipt_schema "ash_a2a.gall.finding-admission/v26.9.18"
  @sha ~r/\A[0-9a-f]{40}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @finding_types ~w(process_deviation conformance_delta semantic_attribution_delta multi_clock_violation prediction_error)
  @candidate_classes ~w(construct_command observe request_authority)
  @evidence_classes ~w(process-conformance object-centric-observation process-attribution multi-clock-conformance)

  @type admission :: %{finding: map(), admission_receipt: map()}

  @spec admit(map(), keyword()) :: {:ok, admission()} | {:error, term()}
  def admit(finding, opts \\ []) when is_map(finding) and is_list(opts) do
    finding = json_value(finding)
    producer = Map.get(finding, "producer", %{})

    with :ok <- equal(:schema, finding["schema"], @schema),
         :ok <- equal(:authority, finding["authority"], "NONE"),
         :ok <- public_ontology(finding),
         :ok <- repository(producer["repository"]),
         :ok <- producer_sha(producer["sha"]),
         :ok <- digest(:producer_receipt_digest, producer["receipt_digest"]),
         :ok <- digest(:evidence_digest, finding["evidence_digest"]),
         :ok <- nonempty(:semantic_subject, finding["semantic_subject"]),
         :ok <- nonempty(:process_subject, finding["process_subject"]),
         :ok <- member(:finding_type, finding["finding_type"], @finding_types),
         :ok <- nonempty(:horizon, finding["horizon"]),
         :ok <-
           member(
             :requested_candidate_class,
             finding["requested_candidate_class"],
             @candidate_classes
           ),
         :ok <- member(:evidence_class, finding["evidence_class"], evidence_classes(opts)),
         :ok <- expected(:repository, producer["repository"], opts[:expected_repository]),
         :ok <- expected(:producer_sha, producer["sha"], opts[:expected_producer_sha]),
         :ok <-
           expected(
             :producer_receipt_digest,
             producer["receipt_digest"],
             opts[:expected_producer_receipt_digest]
           ),
         :ok <-
           expected(
             :semantic_subject,
             finding["semantic_subject"],
             opts[:expected_semantic_subject]
           ),
         :ok <-
           expected(:process_subject, finding["process_subject"], opts[:expected_process_subject]) do
      finding_digest = canonical_digest(finding)

      receipt = %{
        "schema" => @receipt_schema,
        "finding_digest" => finding_digest,
        "producer" => producer,
        "evidence_digest" => finding["evidence_digest"],
        "evidence_class" => finding["evidence_class"],
        "semantic_subject" => finding["semantic_subject"],
        "process_subject" => finding["process_subject"],
        "standing" => "CANDIDATE",
        "authority" => "NONE"
      }

      {:ok, %{finding: finding, admission_receipt: receipt}}
    end
  end

  def admit(_finding, _opts),
    do: refuse(:invalid_envelope, "finding must be a map")

  @doc "Canonical SHA-256 identity used for the admitted finding envelope."
  @spec canonical_digest(term()) :: String.t()
  def canonical_digest(value) do
    "sha256:" <>
      (:crypto.hash(:sha256, canonical_json(json_value(value)))
       |> Base.encode16(case: :lower))
  end

  defp evidence_classes(opts) do
    case Keyword.get(opts, :allowed_evidence_classes) do
      nil -> @evidence_classes
      classes when is_list(classes) -> Enum.map(classes, &to_string/1)
    end
  end

  defp public_ontology(%{"ontology_scope" => scope}) when scope in ["private", "secret"],
    do: refuse(:private_ontology, "private/secret ontology input is outside the public finding boundary")

  defp public_ontology(_), do: :ok

  defp repository(value) when is_binary(value) do
    case String.split(value, "/", parts: 3) do
      [owner, name] when owner != "" and name != "" -> :ok
      _ -> refuse(:invalid_producer_repository, value)
    end
  end

  defp repository(value), do: refuse(:invalid_producer_repository, value)

  defp producer_sha(value) when is_binary(value) do
    if Regex.match?(@sha, value),
      do: :ok,
      else: refuse(:invalid_producer_sha, value)
  end

  defp producer_sha(value), do: refuse(:invalid_producer_sha, value)

  defp digest(field, value) when is_binary(value) do
    if Regex.match?(@digest, value),
      do: :ok,
      else: refuse(:invalid_digest, %{field: field, value: value})
  end

  defp digest(field, value), do: refuse(:invalid_digest, %{field: field, value: value})

  defp nonempty(_field, value) when is_binary(value) and value != "", do: :ok
  defp nonempty(field, value), do: refuse(:invalid_field, %{field: field, value: value})

  defp member(_field, value, allowed) when value in allowed, do: :ok
  defp member(field, value, allowed), do: refuse(:unsupported_value, %{field: field, value: value, allowed: allowed})

  defp equal(_field, value, value), do: :ok
  defp equal(field, actual, expected), do: refuse(:identity_mismatch, %{field: field, expected: expected, actual: actual})

  defp expected(_field, _actual, nil), do: :ok
  defp expected(_field, expected, expected), do: :ok
  defp expected(field, actual, expected), do: refuse(:stale_or_mismatched_subject, %{field: field, expected: expected, actual: actual})

  defp refuse(code, detail), do: {:error, {:refused_process_finding, code, detail}}

  defp json_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), json_value(item)} end)
    |> Map.new()
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(true), do: true
  defp json_value(false), do: false
  defp json_value(nil), do: nil
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: value

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, item} ->
        JSON.encode!(key) <> ":" <> canonical_json(item)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(nil), do: "null"
  defp canonical_json(value), do: JSON.encode!(value)
end

defmodule AshA2A.Gall.ProcessIntervention do
  @moduledoc """
  GALL-030 bounded process intervention.

  The finding can CONSTRUCT a command candidate but grants no DO authority.
  Actual consequence routes exactly once through AshA2A.CommandBus after an
  independently supplied Authority matches capability, target, scope and
  budget. A verified independent postcondition is mandatory for COMPLETED
  standing; otherwise the observed consequence is returned as a
  ROLLBACK_CANDIDATE rather than promoted.
  """

  alias AshA2A.{Authority, Command, CommandBus, Postcondition, Receipt}

  @schema "ash_a2a.gall.process-intervention/v26.9.18"

  @spec construct(AshA2A.Gall.ProcessFinding.admission(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def construct(%{finding: finding, admission_receipt: admission}, attrs) do
    attrs = Map.new(attrs)

    with "CANDIDATE" <- admission["standing"] || {:error, :finding_not_candidate},
         "NONE" <- admission["authority"] || {:error, :finding_has_authority},
         "construct_command" <-
           finding["requested_candidate_class"] || {:error, :candidate_class_mismatch},
         {:ok, capability_id} <- required_string(attrs, :capability_id),
         {:ok, target} <- required_string(attrs, :target),
         {:ok, principal_id} <- required(attrs, :principal_id),
         {:ok, agent_id} <- required(attrs, :agent_id),
         {:ok, command_id} <- required(attrs, :command_id),
         {:ok, scope} <- required(attrs, :scope),
         {:ok, budget} <- required(attrs, :budget) do
      metadata =
        attrs
        |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
        |> Map.new()
        |> Map.put(:gall_finding_digest, admission["finding_digest"])
        |> Map.put(:idempotency_key, "gall:" <> admission["finding_digest"])

      command =
        Command.new(capability_id,
          command_id: command_id,
          agent_id: agent_id,
          principal_id: principal_id,
          task_id: Map.get(attrs, :task_id, Map.get(attrs, "task_id")),
          input: Map.get(attrs, :input, Map.get(attrs, "input", %{})),
          metadata: metadata
        )

      {:ok,
       %{
         schema: @schema,
         finding_digest: admission["finding_digest"],
         command: command,
         target: target,
         scope: scope,
         budget: budget,
         authority: "NONE",
         standing: "CANDIDATE"
       }}
    else
      {:error, reason} -> refusal(reason)
      other -> refusal(other)
    end
  end

  def construct(_admission, _attrs), do: refusal(:invalid_admission)

  @spec execute(map(), A2A.Message.t(), module(), Authority.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def execute(candidate, %A2A.Message{} = message, resource_or_domain, %Authority{} = authority, opts \\ []) do
    with :ok <- candidate_ready(candidate),
         :ok <- target_matches(candidate.target, resource_or_domain),
         :ok <- authority_matches(candidate, authority),
         %Postcondition{} = postcondition <- Keyword.get(opts, :postcondition) ||
           {:error, :postcondition_required} do
      command = authorize(candidate.command, authority)
      bus_opts =
        opts
        |> Keyword.put(:postcondition, postcondition)
        |> Keyword.put_new(:idempotency_key, "gall:" <> candidate.finding_digest)

      case CommandBus.run(command, message, resource_or_domain, bus_opts) do
        {:ok, %Receipt{} = receipt} ->
          case get_in(receipt.metadata, [:postcondition, :status]) do
            :verified ->
              {:ok,
               %{
                 standing: "COMPLETED",
                 finding_digest: candidate.finding_digest,
                 receipt: receipt
               }}

            status ->
              {:error,
               %{
                 code: :independent_postcondition_unverified,
                 standing: "ROLLBACK_CANDIDATE",
                 finding_digest: candidate.finding_digest,
                 postcondition_status: status,
                 receipt: receipt
               }}
          end

        {:error, %{receipt: %Receipt{} = receipt} = error} ->
          {:error,
           error
           |> Map.put(:standing, "ROLLBACK_CANDIDATE")
           |> Map.put(:finding_digest, candidate.finding_digest)
           |> Map.put(:receipt, receipt)}

        {:error, error} when is_map(error) ->
          {:error,
           error
           |> Map.put_new(:standing, "REFUSED")
           |> Map.put(:finding_digest, candidate.finding_digest)}
      end
    else
      {:error, reason} -> refusal_map(reason)
      other -> refusal_map(other)
    end
  end

  def execute(_candidate, _message, _resource_or_domain, _authority, _opts),
    do: refusal_map(:invalid_intervention_request)

  defp candidate_ready(%{
         schema: @schema,
         authority: "NONE",
         standing: "CANDIDATE",
         command: %Command{}
       }),
       do: :ok

  defp candidate_ready(_), do: {:error, :candidate_not_admitted}

  defp target_matches(target, resource_or_domain) do
    actual = inspect(resource_or_domain)
    if target == actual, do: :ok, else: {:error, {:target_mismatch, target, actual}}
  end

  defp authority_matches(candidate, authority) do
    command = candidate.command

    with true <-
           Authority.admits?(authority, %{
             principal_id: command.principal_id,
             capability_id: command.capability_id
           }) || {:error, :authority_identity_mismatch},
         :ok <- exact_constraint(authority, :target, candidate.target),
         :ok <- exact_constraint(authority, :scope, candidate.scope),
         :ok <- exact_constraint(authority, :budget, candidate.budget) do
      :ok
    end
  end

  defp exact_constraint(%Authority{constraints: constraints}, key, expected) do
    actual = Map.get(constraints, key, Map.get(constraints, to_string(key)))

    if actual == expected,
      do: :ok,
      else: {:error, {:authority_constraint_mismatch, key, expected, actual}}
  end

  defp authorize(%Command{} = command, %Authority{} = authority) do
    Command.new(command.capability_id,
      command_id: command.command_id,
      agent_id: command.agent_id,
      principal_id: command.principal_id,
      task_id: command.task_id,
      authority: authority,
      input: command.input,
      submitted_at: command.submitted_at,
      metadata: command.metadata
    )
  end

  defp required(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, to_string(key)))
    if is_nil(value), do: {:error, {:missing_field, key}}, else: {:ok, value}
  end

  defp required_string(attrs, key) do
    with {:ok, value} <- required(attrs, key),
         true <- is_binary(value) and value != "" do
      {:ok, value}
    else
      false -> {:error, {:invalid_field, key}}
      {:error, _} = error -> error
    end
  end

  defp refusal(reason), do: {:error, {:refused_process_intervention, reason}}

  defp refusal_map(reason) do
    %{
      code: :process_intervention_refused,
      detail: reason,
      standing: "REFUSED"
    }
    |> then(&{:error, &1})
  end
end
