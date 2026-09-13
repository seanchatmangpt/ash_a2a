defmodule AshA2A.RuntimeReceipt do
  @moduledoc """
  Evidence for consequence-bearing runtime/provider operations.

  Runtime receipts deliberately carry only observed provider standing. They do
  not confer Ash domain standing, A2A task completion, command execution, or
  authority.
  """

  alias AshA2A.Identity

  @enforce_keys [:receipt_id, :provider, :operation, :subject, :status, :recorded_at]
  defstruct [
    :receipt_id,
    :provider,
    :operation,
    :subject,
    :status,
    :result,
    :recorded_at,
    standing: :observed,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(atom(), atom(), term(), term(), keyword()) :: t()
  def new(provider, operation, subject, result, opts \\ []) do
    %__MODULE__{
      receipt_id: Identity.runtime(Ash.UUIDv7.generate()),
      provider: provider,
      operation: operation,
      subject: normalize_subject(subject),
      status: status(result),
      result: summarize(result),
      recorded_at: DateTime.utc_now(),
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }
  end

  defp normalize_subject(%Identity{} = identity), do: Identity.external(identity)
  defp normalize_subject(subject), do: subject

  defp status(:ok), do: :completed
  defp status({:ok, _}), do: :completed
  defp status({:error, _}), do: :failed
  defp status(_), do: :observed

  defp summarize({:ok, {pid, meta}}) when is_pid(pid),
    do: {:ok, %{pid: inspect(pid), metadata: meta}}

  defp summarize({pid, meta}) when is_pid(pid), do: %{pid: inspect(pid), metadata: meta}
  defp summarize(result), do: result
end
