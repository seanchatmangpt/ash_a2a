defmodule AshA2A.Reactor.BuildCommand do
  @moduledoc """
  Reactor step that builds and shape-validates a real `AshA2A.Command`
  envelope from raw `AshA2A.Reactor.CommandWorkflow` inputs.

  This exists as its own real `Reactor.Step` (not inlined into the
  workflow's `execute_command` arguments) so `AshA2A.Reactor.CommandWorkflow`
  is a genuine multi-node DAG: `result(:build_command)` is a real dependency
  edge the Reactor scheduler resolves before `AshA2A.Reactor.ExecuteCommand`
  ever runs, not a hand-chained function call. `AshA2A.Command.new/2` already
  performs real identity-shape validation (`AshA2A.Identity.new/2` raises
  `ArgumentError` on a malformed identity); this step's job is to surface
  that as a typed Reactor step failure (`{:error, ...}`) instead of letting
  it crash the run as a raw, unclassified exception.
  """

  use Reactor.Step

  alias AshA2A.Command

  @impl true
  def run(arguments, _context, _options) do
    capability_id = Map.fetch!(arguments, :capability_id)
    agent_id = Map.fetch!(arguments, :agent_id)
    principal_id = Map.fetch!(arguments, :principal_id)
    input = Map.get(arguments, :input) || %{}
    authority = Map.get(arguments, :authority)
    command_id = Map.get(arguments, :command_id)

    opts =
      [agent_id: agent_id, principal_id: principal_id, input: input, authority: authority]
      |> maybe_put(:command_id, command_id)

    {:ok, Command.new(capability_id, opts)}
  rescue
    error in [ArgumentError, KeyError] ->
      {:error, %{code: :invalid_command_input, detail: Exception.message(error)}}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
