defmodule AshA2A.ExecutionSnapshot do
  @moduledoc """
  Durable task state independent of any one worker process.

  An execution snapshot is descriptive and authority-free. It lets a different
  worker reconstruct admitted work after a crash without turning worker
  identity, cache state, or transport reachability into execution authority.
  """

  @enforce_keys [
    :task_id,
    :exact_subject,
    :capability_digest,
    :execution_manifest_digest
  ]
  defstruct [
    :task_id,
    :exact_subject,
    :capability_digest,
    :semantic_request_digest,
    :history_digest,
    :tool_surface_digest,
    :ontology_digest,
    :policy_digest,
    :effect_digest,
    :authority_requirement,
    :planner_snapshot,
    :execution_manifest_digest,
    :provider_projection,
    :root_task_id,
    :parent_task_id,
    :delegation_policy,
    :worker_id,
    :checkpoint,
    :consequence_receipt_id,
    :created_at,
    sequence: 0,
    depth: 0,
    state: :queued
  ]

  @type state ::
          :queued
          | :claimed
          | :running
          | :checkpointed
          | :reclaimable
          | :completed
          | :refused

  @type t :: %__MODULE__{state: state()}

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    snapshot = struct!(__MODULE__, attrs)

    for field <- [:task_id, :exact_subject, :capability_digest, :execution_manifest_digest] do
      value = Map.fetch!(snapshot, field)

      if not is_binary(value) or String.trim(value) == "" do
        raise ArgumentError, "#{field} must be a non-empty string"
      end
    end

    %{snapshot | created_at: snapshot.created_at || System.system_time(:millisecond)}
  end

  @spec claim(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def claim(%__MODULE__{state: state} = snapshot, worker_id)
      when state in [:queued, :reclaimable] and is_binary(worker_id) and worker_id != "" do
    {:ok, %{snapshot | state: :claimed, worker_id: worker_id}}
  end

  def claim(%__MODULE__{}, _worker_id), do: {:error, :claim_not_allowed}

  @spec start(t()) :: {:ok, t()} | {:error, atom()}
  def start(%__MODULE__{state: :claimed} = snapshot),
    do: {:ok, %{snapshot | state: :running}}

  def start(%__MODULE__{}), do: {:error, :start_not_allowed}

  @spec checkpoint(t(), non_neg_integer(), String.t()) :: {:ok, t()} | {:error, atom()}
  def checkpoint(
        %__MODULE__{state: state, sequence: current} = snapshot,
        sequence,
        history_digest
      )
      when state in [:running, :checkpointed] and is_integer(sequence) and sequence > current and
             is_binary(history_digest) and history_digest != "" do
    checkpoint = %{
      sequence: sequence,
      history_digest: history_digest,
      worker_id: snapshot.worker_id,
      exact_subject: snapshot.exact_subject,
      execution_manifest_digest: snapshot.execution_manifest_digest
    }

    {:ok,
     %{
       snapshot
       | state: :checkpointed,
         sequence: sequence,
         history_digest: history_digest,
         checkpoint: checkpoint
     }}
  end

  def checkpoint(%__MODULE__{}, _sequence, _history_digest),
    do: {:error, :checkpoint_not_monotonic}

  @spec worker_lost(t()) :: {:ok, t()} | {:error, atom()}
  def worker_lost(%__MODULE__{state: state} = snapshot) when state in [:running, :checkpointed] do
    {:ok, %{snapshot | state: :reclaimable, worker_id: nil}}
  end

  def worker_lost(%__MODULE__{}), do: {:error, :worker_loss_not_applicable}

  @spec complete(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def complete(
        %__MODULE__{state: :completed, consequence_receipt_id: receipt} = snapshot,
        receipt
      ),
      do: {:ok, snapshot}

  def complete(%__MODULE__{state: :completed}, _receipt),
    do: {:error, :duplicate_consequence}

  def complete(%__MODULE__{state: state} = snapshot, receipt_id)
      when state in [:running, :checkpointed] and is_binary(receipt_id) and receipt_id != "" do
    {:ok, %{snapshot | state: :completed, consequence_receipt_id: receipt_id}}
  end

  def complete(%__MODULE__{}, _receipt_id), do: {:error, :completion_not_allowed}

  @spec refuse(t(), atom()) :: {:ok, t()}
  def refuse(%__MODULE__{} = snapshot, reason) when is_atom(reason) do
    {:ok, %{snapshot | state: :refused, provider_projection: %{refusal: reason}}}
  end

  @doc """
  Stable local identity for cache/topology use only.

  This digest is not admission, authority, execution proof, or standing.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> :crypto.hash(:sha256)
    |> Base.encode16(case: :lower)
  end
end
