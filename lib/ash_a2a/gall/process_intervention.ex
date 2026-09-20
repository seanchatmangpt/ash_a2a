defmodule AshA2A.Gall.ProcessIntervention do
  @moduledoc """
  GALL-029 finding admission and GALL-030 bounded intervention.

  Findings remain evidence, never authority. Only AshA2A.CommandBus.run/4
  crosses DO, and an independent observer callback is required before this
  module reports an intervention as verified.
  """

  alias AshA2A.{Command, CommandBus, Receipt}

  @finding_classes ~w(conformance prediction attribution postcondition)
  @horizons ~w(FAST MEDIUM SLOW)
  @secret_keys ~w(token password secret credential authorization bearer api_key private_key)

  @spec admit(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit(finding, opts \\ []) when is_map(finding) do
    allowed_producers = Keyword.get(opts, :allowed_producers, [])
    public_vocab = Keyword.get(opts, :public_vocabulary, [])

    with :ok <- no_secrets(finding),
         :ok <- sha(finding[:producer_sha] || finding["producer_sha"], :producer_sha, 40),
         :ok <- digest(finding[:evidence_digest] || finding["evidence_digest"], :evidence_digest),
         :ok <-
           digest(
             finding[:semantic_subject_digest] || finding["semantic_subject_digest"],
             :semantic_subject_digest
           ),
         :ok <-
           member(
             finding[:finding_class] || finding["finding_class"],
             @finding_classes,
             :finding_class
           ),
         :ok <- member(finding[:horizon] || finding["horizon"], @horizons, :horizon),
         :ok <- producer_allowed(finding, allowed_producers),
         :ok <- vocabulary_allowed(finding, public_vocab),
         {:ok, capability_id} <- capability(finding) do
      base = %{
        schema: "ash_a2a.gall.process-candidate/v26.9.18",
        finding_digest: canonical_digest(finding),
        producer_sha: finding[:producer_sha] || finding["producer_sha"],
        semantic_subject_digest: finding[:semantic_subject_digest] || finding["semantic_subject_digest"],
        finding_class: finding[:finding_class] || finding["finding_class"],
        horizon: finding[:horizon] || finding["horizon"],
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
    observer = Keyword.get(opts, :independent_observer)

    with :ok <- admitted_candidate(candidate),
         :ok <- command_binding(candidate, command),
         :ok <- require_observer(observer),
         {:ok, %Receipt{} = receipt} <- CommandBus.run(command, message, resource_or_domain, opts),
         {:ok, observer_receipt} <- observer.(candidate, receipt),
         :ok <- observer_binding(candidate, receipt, observer_receipt) do
      {:ok, %{command_receipt: receipt, observer_receipt: observer_receipt}}
    end
  end

  defp require_observer(fun) when is_function(fun, 2), do: :ok
  defp require_observer(_), do: {:error, :independent_observer_required}

  defp admitted_candidate(%{schema: "ash_a2a.gall.process-candidate/v26.9.18", authority: :none} = c) do
    expected = c |> Map.delete(:candidate_digest) |> canonical_digest()
    if c.candidate_digest == expected, do: :ok, else: {:error, :candidate_digest_mismatch}
  end
  defp admitted_candidate(_), do: {:error, :gall_029_admission_required}

  defp command_binding(candidate, command) do
    bound =
      command.metadata[:gall_029_candidate_digest] || command.metadata["gall_029_candidate_digest"]

    cond do
      command.capability_id != candidate.capability_id -> {:error, :capability_mismatch}
      bound != candidate.candidate_digest -> {:error, :candidate_binding_mismatch}
      true -> :ok
    end
  end

  defp observer_binding(candidate, receipt, observer) when is_map(observer) do
    command_id = AshA2A.Identity.external(receipt.command_id)
    cond do
      (observer[:independent] || observer["independent"]) != true ->
        {:error, :observer_not_independent}
      (observer[:candidate_digest] || observer["candidate_digest"]) !=
          candidate.candidate_digest ->
        {:error, :observer_candidate_mismatch}
      (observer[:command_id] || observer["command_id"]) != command_id ->
        {:error, :observer_command_mismatch}
      (observer[:postcondition] || observer["postcondition"]) != "verified" ->
        {:error, :postcondition_not_verified}
      true -> :ok
    end
  end
  defp observer_binding(_, _, _), do: {:error, :invalid_observer_receipt}

  defp capability(finding) do
    case finding[:requested_capability_id] || finding["requested_capability_id"] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :requested_capability_id}
    end
  end

  defp producer_allowed(_finding, []), do: :ok

  defp producer_allowed(finding, allowed) do
    producer = finding[:producer_sha] || finding["producer_sha"]
    if producer in allowed, do: :ok, else: {:error, :stale_or_unadmitted_producer}
  end

  defp vocabulary_allowed(_finding, []), do: :ok

  defp vocabulary_allowed(finding, allowed) do
    vocab = finding[:vocabulary] || finding["vocabulary"]
    if vocab in allowed, do: :ok, else: {:error, :private_or_unknown_vocabulary}
  end

  defp no_secrets(value) when is_map(value) do
    case Enum.find(value, fn {k, v} ->
           String.downcase(to_string(k)) in @secret_keys or secret_value?(v)
         end) do
      nil ->
        Enum.reduce_while(value, :ok, fn {_k, v}, :ok ->
          case no_secrets(v) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      _ -> {:error, :secret_bearing_finding}
    end
  end

  defp no_secrets(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn v, :ok ->
      case no_secrets(v) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
  defp no_secrets(_), do: :ok

  defp secret_value?(v) when is_binary(v), do: String.starts_with?(String.downcase(v), "bearer ")
  defp secret_value?(_), do: false

  defp member(value, allowed, field), do: if(value in allowed, do: :ok, else: {:error, field})
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
    do: value |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
