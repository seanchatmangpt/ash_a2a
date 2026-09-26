defmodule AshA2A.ConditionalCommitment do
  @moduledoc """
  Deterministic classification of a command's standing before consequential DO.

  This module does not actuate and does not manufacture authority. It projects
  already-existing AshA2A objects into the distinction required by the
  governance-gate contract:

      proposal != authority != prepared consequence

  AshA2A.BrceAnchor remains the sole-DO fence. This module is an upstream
  classifier and observation surface. A request for approval is never
  represented as approval, and an authority grant alone is never represented
  as permission to cross BRCE.
  """

  alias AshA2A.{Authority, Command, Identity, Receipt}

  @type standing :: :proposed | :authorized | :prepared | :refused

  @enforce_keys [:standing, :authorized?, :prepared?, :ready_for_do?]
  defstruct [:standing, :refusal_code, authorized?: false, prepared?: false, ready_for_do?: false]

  @type t :: %__MODULE__{
          standing: standing(),
          refusal_code: atom() | nil,
          authorized?: boolean(),
          prepared?: boolean(),
          ready_for_do?: boolean()
        }

  @spec classify(Command.t(), Receipt.t() | nil) :: t()
  def classify(%Command{} = command, receipt \\ nil) do
    authorized? = Authority.admits?(command.authority, command)

    case receipt_binding(command, receipt) do
      :absent ->
        decision(if(authorized?, do: :authorized, else: :proposed), authorized?, false, nil)

      :match when authorized? ->
        decision(:prepared, true, true, nil)

      :match ->
        decision(:refused, false, true, :authority_required)

      {:mismatch, reason} ->
        decision(:refused, authorized?, false, reason)
    end
  end

  @doc "True only when current authority and the exact pending receipt are both present."
  @spec ready_for_do?(Command.t(), Receipt.t() | nil) :: boolean()
  def ready_for_do?(%Command{} = command, receipt \\ nil) do
    classify(command, receipt).ready_for_do?
  end

  @doc """
  Deterministic digest of the exact command/receipt commitment projection.

  The digest is observation identity only. It confers no authority and is not
  an idempotency token for actuation.
  """
  @spec digest(Command.t(), Receipt.t() | nil) :: String.t()
  def digest(%Command{} = command, receipt \\ nil) do
    decision = classify(command, receipt)

    {
      Identity.external(command.command_id),
      command.capability_id,
      command.fingerprint,
      receipt_identity(receipt),
      decision.standing,
      decision.authorized?,
      decision.prepared?,
      decision.ready_for_do?,
      decision.refusal_code
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Bounded telemetry/OCEL-safe projection of commitment standing.

  No raw authority evidence or command input is included.
  """
  @spec metadata(Command.t(), Receipt.t() | nil) :: map()
  def metadata(%Command{} = command, receipt \\ nil) do
    decision = classify(command, receipt)

    %{
      commitment_standing: decision.standing,
      commitment_authorized: decision.authorized?,
      commitment_prepared: decision.prepared?,
      commitment_ready_for_do: decision.ready_for_do?,
      commitment_refusal_code: decision.refusal_code,
      commitment_digest: digest(command, receipt),
      prepared_receipt_id: receipt_identity(receipt)
    }
  end

  defp receipt_binding(_command, nil), do: :absent

  defp receipt_binding(%Command{} = command, %Receipt{status: :pending} = receipt) do
    cond do
      receipt.command_id != command.command_id -> {:mismatch, :command_id_mismatch}
      receipt.capability_id != command.capability_id -> {:mismatch, :capability_mismatch}
      receipt.fingerprint != command.fingerprint -> {:mismatch, :fingerprint_mismatch}
      true -> :match
    end
  end

  defp receipt_binding(_command, %Receipt{}), do: {:mismatch, :receipt_not_pending}

  defp receipt_identity(%Receipt{receipt_id: %Identity{} = receipt_id}),
    do: Identity.external(receipt_id)

  defp receipt_identity(_), do: nil

  defp decision(standing, authorized?, prepared?, refusal_code) do
    %__MODULE__{
      standing: standing,
      authorized?: authorized?,
      prepared?: prepared?,
      ready_for_do?: standing == :prepared,
      refusal_code: refusal_code
    }
  end
end
