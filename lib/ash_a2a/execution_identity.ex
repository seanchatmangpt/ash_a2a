defmodule AshA2A.ExecutionIdentity do
  @moduledoc """
  Canonical bridge from an admitted HILT work order + SA2A command to a
  durable AshA2A.ExecutionSnapshot identity.

  Provider, transport, worker and run identifiers are absent by construction.
  Authority is bound by grant identity and constraints, never by transport
  evidence. Consequence identity is derived from the existing S55 Actuation
  effect identity instead of inventing a second effect model.
  """

  alias AshA2A.{Actuation, Authority, Command, ExecutionSnapshot, Identity}
  alias AshA2A.Hilt.WorkOrder

  @enforce_keys [
    :task_id,
    :work_order_digest,
    :command_digest,
    :exact_subject,
    :candidate_digest,
    :authority_digest,
    :consequence_digest,
    :capability_digest
  ]

  defstruct [
    :task_id,
    :work_order_digest,
    :command_digest,
    :exact_subject,
    :candidate_digest,
    :authority_digest,
    :consequence_digest,
    :capability_digest
  ]

  @type t :: %__MODULE__{}

  @doc "Derives the exact provider-independent execution identity."
  @spec from_work_order!(WorkOrder.t(), Command.t()) :: t()
  def from_work_order!(%WorkOrder{} = work_order, %Command{} = command) do
    case WorkOrder.admit_command(work_order, command) do
      :ok -> build(work_order, command)
      {:error, reason} -> raise ArgumentError, "work order refused command: #{reason}"
    end
  end

  @doc "Creates a durable snapshot without allowing callers to reassemble identity fields."
  @spec snapshot!(t(), String.t(), keyword()) :: ExecutionSnapshot.t()
  def snapshot!(%__MODULE__{} = identity, execution_manifest_digest, opts \\ [])
      when is_binary(execution_manifest_digest) and execution_manifest_digest != "" do
    reserved = Map.keys(Map.from_struct(identity)) ++ [:execution_manifest_digest]
    attempted = Enum.filter(Keyword.keys(opts), &(&1 in reserved))

    if attempted != [] do
      raise ArgumentError,
            "snapshot identity fields are derived, not caller-set: #{inspect(attempted)}"
    end

    opts
    |> Keyword.merge(Map.to_list(Map.from_struct(identity)))
    |> Keyword.put(:execution_manifest_digest, execution_manifest_digest)
    |> ExecutionSnapshot.new!()
  end

  @doc "Verifies that a snapshot still carries exactly this execution identity."
  @spec verify_snapshot(t(), ExecutionSnapshot.t()) :: :ok | {:error, {:identity_drift, [atom()]}}
  def verify_snapshot(%__MODULE__{} = identity, %ExecutionSnapshot{} = snapshot) do
    expected = Map.from_struct(identity)

    drift =
      expected
      |> Map.keys()
      |> Enum.filter(&(Map.fetch!(expected, &1) != Map.fetch!(snapshot, &1)))
      |> Enum.sort()

    if drift == [], do: :ok, else: {:error, {:identity_drift, drift}}
  end

  defp build(work_order, command) do
    actuation = Actuation.identity(command)

    %__MODULE__{
      task_id: work_order.task_id,
      work_order_digest: WorkOrder.identity_digest(work_order),
      command_digest: "sha256:" <> command.fingerprint,
      exact_subject: work_order.exact_subject_digest,
      candidate_digest: work_order.candidate_digest,
      authority_digest: authority_digest(command.authority),
      consequence_digest:
        Actuation.digest({work_order.consequence_class, actuation.effect_digest}),
      capability_digest:
        Actuation.digest({work_order.capability_id, work_order.action_bounds_digest})
    }
  end

  defp authority_digest(nil), do: Actuation.digest(:no_authority)

  defp authority_digest(%Authority{} = authority) do
    Actuation.digest({
      Identity.external(authority.token_id),
      Identity.external(authority.subject),
      authority.capability_id,
      authority.source,
      authority.issued_at,
      authority.expires_at,
      authority.constraints
    })
  end
end
