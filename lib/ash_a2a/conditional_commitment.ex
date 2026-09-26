defmodule AshA2A.ConditionalCommitment do
  @moduledoc """
  Deterministic classification of a command's standing before consequential DO.

  This module does not actuate and does not manufacture authority. It projects
  already-existing AshA2A objects into the distinction required by the
  governance-gate contract:

      proposal != authority != prepared consequence

  AshA2A.BrceAnchor remains the sole-DO fence. This module is an upstream
  classifier that lets planners, agents, and governance surfaces ask whether a
  command is merely proposed, currently authorized, or actually backed by the
  exact pending receipt that BRCE requires before DO.

  A request for approval is therefore never represented as approval, and an
  authority grant alone is never represented as permission to cross BRCE.
  """

  alias AshA2A.{Authority, Command, Receipt}

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

  @doc """
  Classify an existing command and optional prepared receipt.

  The classifier is deliberately strict:
  * a command with no matching live authority is only a proposal;
  * a matching authority without a pending receipt is authorized but not ready;
  * a pending receipt must bind the exact command id, capability, and fingerprint;
  * a mismatched receipt is a typed refusal, never evidence of preparation.

  ready_for_do? can only be true for :prepared.
  """
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
