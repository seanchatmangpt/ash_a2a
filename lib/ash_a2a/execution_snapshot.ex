defmodule AshA2A.ExecutionSnapshot do
  @moduledoc """
  Durable task state independent of any one worker process.

  An execution snapshot is descriptive and authority-free. It lets a different
  worker reconstruct admitted work after a crash without turning worker,
  provider, run, cache, or transport identity into execution authority.

  Semantic work identity is the explicit product of work order, command,
  exact subject, admitted candidate, authority grant, intended consequence,
  capability, and execution manifest identities. Provider/runtime topology is
  deliberately excluded from that product.
  """

  @version 1

  @required_identity_fields [
    :task_id,
    :work_order_digest,
    :command_digest,
    :exact_subject,
    :candidate_digest,
    :authority_digest,
    :consequence_digest,
    :capability_digest,
    :execution_manifest_digest
  ]

  @enforce_keys @required_identity_fields
  defstruct [
    :task_id,
    :work_order_digest,
    :command_digest,
    :exact_subject,
    :candidate_digest,
    :authority_digest,
    :consequence_digest,
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
    :consequence_receipt_digest,
    :refusal,
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

  @semantic_identity_fields [
    :task_id,
    :work_order_digest,
    :command_digest,
    :exact_subject,
    :candidate_digest,
    :authority_digest,
    :consequence_digest,
    :capability_digest,
    :semantic_request_digest,
    :tool_surface_digest,
    :ontology_digest,
    :policy_digest,
    :effect_digest,
    :authority_requirement,
    :planner_snapshot,
    :execution_manifest_digest,
    :root_task_id,
    :parent_task_id,
    :delegation_policy,
    :depth
  ]

  @doc "Identity fields that must be present before a snapshot can exist."
  @spec required_identity_fields() :: [atom()]
  def required_identity_fields, do: @required_identity_fields

  @doc "Fields that define provider-independent semantic execution identity."
  @spec semantic_identity_fields() :: [atom()]
  def semantic_identity_fields, do: @semantic_identity_fields

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    snapshot = struct!(__MODULE__, attrs)

    Enum.each(@required_identity_fields, fn field ->
      value = Map.fetch!(snapshot, field)

      if not is_binary(value) or String.trim(value) == "" do
        raise ArgumentError, "#{field} must be a non-empty string"
      end
    end)

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
      semantic_identity_digest: semantic_identity_digest(snapshot),
      exact_subject: snapshot.exact_subject,
      command_digest: snapshot.command_digest,
      candidate_digest: snapshot.candidate_digest,
      authority_digest: snapshot.authority_digest,
      consequence_digest: snapshot.consequence_digest,
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

  @doc """
  Completes a snapshot using the legacy receipt-id-only path.

  New consequence-bearing callers should prefer `complete/3` and bind the
  receipt's verified binding/link digest as well as its id.
  """
  @spec complete(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def complete(%__MODULE__{} = snapshot, receipt_id),
    do: complete(snapshot, receipt_id, nil)

  @doc """
  Completes a snapshot with a stable receipt identity and optional verified
  receipt-binding digest.

  Exact replay of the same pair is idempotent. Reuse of the semantic execution
  identity with a different receipt id or a different non-nil binding digest is
  refused.
  """
  @spec complete(t(), String.t(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def complete(
        %__MODULE__{
          state: :completed,
          consequence_receipt_id: receipt_id,
          consequence_receipt_digest: receipt_digest
        } = snapshot,
        receipt_id,
        supplied_digest
      )
      when is_binary(receipt_id) do
    cond do
      is_nil(receipt_digest) and is_nil(supplied_digest) ->
        {:ok, snapshot}

      receipt_digest == supplied_digest ->
        {:ok, snapshot}

      true ->
        {:error, :receipt_binding_mismatch}
    end
  end

  def complete(%__MODULE__{state: :completed}, _receipt_id, _receipt_digest),
    do: {:error, :duplicate_consequence}

  def complete(%__MODULE__{state: state} = snapshot, receipt_id, receipt_digest)
      when state in [:running, :checkpointed] and is_binary(receipt_id) and receipt_id != "" and
             (is_nil(receipt_digest) or (is_binary(receipt_digest) and receipt_digest != "")) do
    {:ok,
     %{
       snapshot
       | state: :completed,
         consequence_receipt_id: receipt_id,
         consequence_receipt_digest: receipt_digest
     }}
  end

  def complete(%__MODULE__{}, _receipt_id, _receipt_digest),
    do: {:error, :completion_not_allowed}

  @spec refuse(t(), atom()) :: {:ok, t()}
  def refuse(%__MODULE__{} = snapshot, reason) when is_atom(reason) do
    {:ok, %{snapshot | state: :refused, refusal: %{reason: reason}}}
  end

  @doc """
  Stable local identity for cache/topology use only.

  This digest intentionally includes provider/worker/lifecycle state. It is not
  admission, authority, execution proof, semantic work identity, or standing.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> canonical_digest()
  end

  @doc """
  Provider-, run-, worker-, transport-, checkpoint-, timestamp-, and
  receipt-independent semantic identity of the admitted work.
  """
  @spec semantic_identity_digest(t()) :: String.t()
  def semantic_identity_digest(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.take(@semantic_identity_fields)
    |> canonical_digest()
  end

  @doc "Replay/dedup key for semantic execution; alias of semantic identity."
  @spec replay_key(t()) :: String.t()
  def replay_key(%__MODULE__{} = snapshot), do: semantic_identity_digest(snapshot)

  @doc """
  Deterministic durable encoding with both semantic and whole-snapshot digests.

  The envelope detects corruption/tampering before lifecycle state is restored.
  It does not grant authority; restored snapshots retain exactly the authority
  identity already bound into the serialized snapshot.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = snapshot) do
    envelope = %{
      version: @version,
      semantic_identity_digest: semantic_identity_digest(snapshot),
      snapshot_digest: digest(snapshot),
      snapshot: Map.from_struct(snapshot)
    }

    :erlang.term_to_binary(envelope, [:deterministic])
  end

  @doc "Restores a snapshot only when both durable envelope digests verify."
  @spec decode!(binary()) :: t()
  def decode!(payload) when is_binary(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      %{
        version: @version,
        semantic_identity_digest: semantic_digest,
        snapshot_digest: snapshot_digest,
        snapshot: %{} = attrs
      } ->
        snapshot = attrs |> Map.to_list() |> new!()

        cond do
          digest(snapshot) != snapshot_digest ->
            raise ArgumentError, "snapshot digest mismatch"

          semantic_identity_digest(snapshot) != semantic_digest ->
            raise ArgumentError, "semantic identity digest mismatch"

          true ->
            snapshot
        end

      _ ->
        raise ArgumentError, "invalid execution snapshot envelope"
    end
  rescue
    ArgumentError = error -> reraise(error, __STACKTRACE__)
    _error -> raise ArgumentError, "invalid execution snapshot envelope"
  end

  defp canonical_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
