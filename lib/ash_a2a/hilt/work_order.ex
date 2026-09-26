defmodule AshA2A.Hilt.WorkOrder do
  @moduledoc """
  Executable HILT work-order contract for the SA2A boundary.

  A work order is not authority and never performs DO. It freezes the semantic
  scope that a later AshA2A.Command must preserve: exact task/subject,
  candidate, capability, bounded observation/action surfaces, authority
  ceiling, consequence class, process evidence and falsifier identity.

  bind_command/2 places the content-addressed work-order identity into command
  metadata. AshA2A.Command.fingerprint/1 treats that field as semantic
  identity, so provider substitution and transport retries preserve the same
  command while stale/reused work orders do not.
  """

  alias AshA2A.{Actuation, Authority, Command, Identity, SemanticSubject}

  @authority_levels [:observe, :select, :construct, :do]
  @consequence_classes [:observe, :change, :external_do, :unknown]

  @enforce_keys [
    :work_order_id,
    :task_id,
    :exact_subject_digest,
    :candidate_digest,
    :capability_id,
    :observation_bounds_digest,
    :action_bounds_digest,
    :authority_ceiling,
    :consequence_class,
    :process_evidence_digest,
    :falsifier_digest
  ]

  defstruct [
    :work_order_id,
    :task_id,
    :exact_subject_digest,
    :candidate_digest,
    :capability_id,
    :observation_bounds_digest,
    :action_bounds_digest,
    :authority_ceiling,
    :consequence_class,
    :process_evidence_digest,
    :falsifier_digest,
    metadata: %{}
  ]

  @type authority_level :: :observe | :select | :construct | :do
  @type consequence_class :: :observe | :change | :external_do | :unknown
  @type t :: %__MODULE__{
          work_order_id: String.t(),
          task_id: String.t(),
          exact_subject_digest: String.t(),
          candidate_digest: String.t(),
          capability_id: String.t(),
          observation_bounds_digest: String.t(),
          action_bounds_digest: String.t(),
          authority_ceiling: authority_level(),
          consequence_class: consequence_class(),
          process_evidence_digest: String.t(),
          falsifier_digest: String.t(),
          metadata: map()
        }

  @identity_fields [
    :work_order_id,
    :task_id,
    :exact_subject_digest,
    :candidate_digest,
    :capability_id,
    :observation_bounds_digest,
    :action_bounds_digest,
    :authority_ceiling,
    :consequence_class,
    :process_evidence_digest,
    :falsifier_digest
  ]

  @doc "Builds a fail-closed work order from explicit, already-bounded identities."
  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    work_order = struct!(__MODULE__, attrs)

    Enum.each(
      [
        :work_order_id,
        :task_id,
        :exact_subject_digest,
        :candidate_digest,
        :capability_id,
        :observation_bounds_digest,
        :action_bounds_digest,
        :process_evidence_digest,
        :falsifier_digest
      ],
      fn field ->
        case Map.fetch!(work_order, field) do
          value when is_binary(value) and byte_size(value) > 0 -> :ok
          _ -> raise ArgumentError, "#{field} must be a non-empty string"
        end
      end
    )

    if work_order.authority_ceiling not in @authority_levels do
      raise ArgumentError, "authority_ceiling must be one of #{inspect(@authority_levels)}"
    end

    if work_order.consequence_class not in @consequence_classes do
      raise ArgumentError, "consequence_class must be one of #{inspect(@consequence_classes)}"
    end

    %{work_order | metadata: Map.new(work_order.metadata || %{})}
  end

  @doc """
  Manufactures a work order from an existing candidate command plus bounded
  observation/action/process/falsifier descriptors.

  This does not bind the command yet; call bind_command/2 after construction.
  """
  @spec for_command!(Command.t(), consequence_class(), keyword()) :: t()
  def for_command!(%Command{} = command, consequence_class, opts) when is_list(opts) do
    task_id =
      case command.task_id do
        %Identity{kind: :task} = identity -> Identity.external(identity)
        _ -> raise ArgumentError, "HILT work order requires command.task_id"
      end

    candidate_digest =
      Command.candidate_digest(command) ||
        raise ArgumentError, "HILT work order requires candidate_digest"

    exact_subject_digest =
      case command.semantic_subject do
        %SemanticSubject{} = subject -> Actuation.digest(SemanticSubject.fingerprint_token(subject))
        _ -> raise ArgumentError, "HILT work order requires an exact semantic subject"
      end

    new!(
      work_order_id: Keyword.fetch!(opts, :work_order_id),
      task_id: task_id,
      exact_subject_digest: exact_subject_digest,
      candidate_digest: candidate_digest,
      capability_id: command.capability_id,
      observation_bounds_digest: digest_bound(Keyword.fetch!(opts, :observation_bounds)),
      action_bounds_digest: digest_bound(Keyword.fetch!(opts, :action_bounds)),
      authority_ceiling: Keyword.fetch!(opts, :authority_ceiling),
      consequence_class: consequence_class,
      process_evidence_digest: digest_bound(Keyword.fetch!(opts, :process_evidence)),
      falsifier_digest: digest_bound(Keyword.fetch!(opts, :falsifier)),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Content-addressed semantic identity of the work order."
  @spec identity_digest(t()) :: String.t()
  def identity_digest(%__MODULE__{} = work_order) do
    work_order
    |> Map.from_struct()
    |> Map.take(@identity_fields)
    |> Actuation.digest()
  end

  @doc """
  Reissues command with this work order bound into identity-bearing metadata.

  Transport/provider metadata remains untouched but is not fingerprint-bearing.
  """
  @spec bind_command(t(), Command.t()) :: Command.t()
  def bind_command(%__MODULE__{} = work_order, %Command{} = command) do
    metadata =
      command.metadata
      |> Map.new()
      |> Map.put(:candidate_digest, work_order.candidate_digest)
      |> Map.put(:work_order_digest, identity_digest(work_order))

    Command.new(command.capability_id,
      command_id: command.command_id,
      agent_id: command.agent_id,
      principal_id: command.principal_id,
      task_id: command.task_id,
      input: command.input,
      authority: command.authority,
      semantic_subject: command.semantic_subject,
      spg_identity: command.spg_identity,
      submitted_at: command.submitted_at,
      metadata: metadata
    )
  end

  @doc """
  Verifies that a bound command is still the command this work order admits.

  This is admission only. It does not replace the authority broker or
  AshA2A.CommandBus consequence boundary.
  """
  @spec admit_command(t(), Command.t()) :: :ok | {:error, atom()}
  def admit_command(%__MODULE__{} = work_order, %Command{} = command) do
    with :ok <- same(:task, work_order.task_id, external_task(command.task_id)),
         :ok <- same(:capability, work_order.capability_id, command.capability_id),
         :ok <- same(:candidate, work_order.candidate_digest, Command.candidate_digest(command)),
         :ok <-
           same(
             :subject,
             work_order.exact_subject_digest,
             subject_digest(command.semantic_subject)
           ),
         :ok <-
           same(
             :work_order,
             identity_digest(work_order),
             Command.work_order_digest(command)
           ),
         :ok <- consequence_within_ceiling(work_order, command) do
      :ok
    end
  end

  defp same(_kind, expected, expected), do: :ok
  defp same(kind, _expected, _actual), do: {:error, String.to_atom("stale_#{kind}_identity")}

  defp external_task(%Identity{kind: :task} = identity), do: Identity.external(identity)
  defp external_task(_), do: nil

  defp subject_digest(%SemanticSubject{} = subject),
    do: Actuation.digest(SemanticSubject.fingerprint_token(subject))

  defp subject_digest(_), do: nil

  defp consequence_within_ceiling(%__MODULE__{consequence_class: :unknown}, _command),
    do: {:error, :consequence_unclassified}

  defp consequence_within_ceiling(%__MODULE__{} = work_order, command) do
    required = consequence_authority(work_order.consequence_class)

    cond do
      level(work_order.authority_ceiling) < level(required) ->
        {:error, :authority_ceiling_exceeded}

      required == :do and not match?(%Authority{}, command.authority) ->
        {:error, :authority_required}

      required == :do and not Authority.admits?(command.authority, command) ->
        {:error, :authority_mismatch}

      true ->
        :ok
    end
  end

  defp consequence_authority(:observe), do: :observe
  defp consequence_authority(:change), do: :do
  defp consequence_authority(:external_do), do: :do
  defp consequence_authority(:unknown), do: :do

  defp level(level), do: Enum.find_index(@authority_levels, &(&1 == level))

  defp digest_bound(value), do: Actuation.digest(value)
end
