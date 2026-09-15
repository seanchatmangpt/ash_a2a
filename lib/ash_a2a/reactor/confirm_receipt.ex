defmodule AshA2A.Reactor.ConfirmReceipt do
  @moduledoc """
  Reactor step reading the real `AshA2A.Receipt` committed by
  `AshA2A.Reactor.ExecuteCommand` and confirming its real `status` before
  `AshA2A.Reactor.CommandWorkflow` returns it.

  A genuine third DAG node consuming a prior step's real result (not a
  passthrough alias): it pattern-matches on the actual `%AshA2A.Receipt{}`
  struct fields rather than re-wrapping an opaque value, so a receipt whose
  real dispatch reply was not `:completed` (e.g. `:input_required`,
  `:failed`) is refused here explicitly rather than silently returned as if
  it were a success.
  """

  use Reactor.Step

  alias AshA2A.Receipt

  @impl true
  def run(%{receipt: %Receipt{status: :completed} = receipt}, _context, _options) do
    {:ok, receipt}
  end

  def run(%{receipt: %Receipt{status: status}}, _context, _options) do
    {:error, %{code: :receipt_not_completed, status: status}}
  end
end
