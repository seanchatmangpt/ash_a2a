defmodule AshA2A.Identity do
  @moduledoc """
  Typed machine identity for the A2A execution boundary.

  Identity kinds are deliberately non-interchangeable: a task id is not an
  agent id, a command id is not an execution id, and none of them imply a
  principal. The tagged value is small enough to pass through A2A metadata,
  Reactor context, Oban arguments, topology providers, and receipts without
  manufacturing a second identity system.
  """

  @kinds [:principal, :agent, :task, :command, :execution, :runtime, :actuation, :idempotency]
  @enforce_keys [:kind, :value]
  defstruct [:kind, :value]

  @typedoc """
  Identity kinds.

    * `:actuation` -- RFC-SA2A-001 S55 stable actuation identity. Derived from
      the *intended effect* (capability, principal, semantic subject, input
      digest, external idempotency token), NOT from `:command`. Two distinct
      command ids naming the same effect share one actuation identity; that is
      the point -- it is what lets BRCE detect a previously prepared or
      executed effect before repeating it.
    * `:idempotency` -- RFC-SA2A-001 S55 idempotency identity. Binds to the
      external system's own idempotency token when the caller supplies one, so
      the local dedup key and the remote dedup key are the same string.
  """
  @type kind ::
          :principal
          | :agent
          | :task
          | :command
          | :execution
          | :runtime
          | :actuation
          | :idempotency
  @type t :: %__MODULE__{kind: kind(), value: String.t()}

  @spec new(kind(), term()) :: t()
  def new(kind, value) when kind in @kinds and not is_nil(value) do
    %__MODULE__{kind: kind, value: normalize(value)}
  end

  def new(kind, value) do
    raise ArgumentError, "invalid AshA2A identity #{inspect({kind, value})}"
  end

  for kind <- @kinds do
    def unquote(kind)(value), do: new(unquote(kind), value)
  end

  @spec external(t()) :: String.t()
  def external(%__MODULE__{kind: kind, value: value}), do: "#{kind}:#{value}"

  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end
