defmodule AshA2A.Replan.Decision do
  @enforce_keys [:kind, :subject, :reason]
  defstruct [:kind, :subject, :reason, :provider, authority: :none]
  def replan(subject, reason), do: %__MODULE__{kind: :replan, subject: subject, reason: reason}
  def stop(subject, reason), do: %__MODULE__{kind: :stop, subject: subject, reason: reason}
end
