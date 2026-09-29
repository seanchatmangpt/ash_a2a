defmodule AuthorityService.ApproverChannel.InMemory do
  @moduledoc """
  In-memory channel: state is `%{approver_id => %{envelope:, message:}}` of responses the
  approvers have already produced. A simple real implementation of the behaviour (it
  returns what was queued, or `{:error, :no_response}`); it holds no private keys.
  """
  @behaviour AuthorityService.ApproverChannel

  @impl true
  def solicit(state, approver_id, _request) do
    case Map.fetch(state, approver_id) do
      {:ok, %{envelope: _, message: _} = r} -> {:ok, r}
      _ -> {:error, :no_response}
    end
  end
end
