defmodule AshA2A.Delivery do
  @moduledoc """
  Provider-neutral observation that a command was handed to an async delivery
  substrate. A delivery is not an execution receipt and provider ids are not
  A2A task ids.
  """

  alias AshA2A.{Command, Identity}

  @enforce_keys [:delivery_id, :command_id, :provider, :status, :recorded_at]
  defstruct [
    :delivery_id,
    :command_id,
    :task_id,
    :provider,
    :provider_ref,
    :status,
    :recorded_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), Command.t(), keyword()) :: t()
  def new(provider, %Command{} = command, opts \\ []) when is_atom(provider) do
    %__MODULE__{
      delivery_id: Ash.UUIDv7.generate(),
      command_id: command.command_id,
      task_id: command.task_id,
      provider: provider,
      provider_ref: Keyword.get(opts, :provider_ref),
      status: Keyword.get(opts, :status, :accepted),
      recorded_at: Keyword.get(opts, :recorded_at, DateTime.utc_now()),
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec task_key(t()) :: String.t() | nil
  def task_key(%__MODULE__{task_id: %Identity{} = task_id}), do: Identity.external(task_id)
  def task_key(%__MODULE__{task_id: nil}), do: nil
end
