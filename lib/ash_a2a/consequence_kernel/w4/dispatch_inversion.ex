defmodule AshA2A.ConsequenceKernel.W4.DispatchInversion do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4.{ConsequenceGate, DispatcherFence, EffectRequest, Outcome}
  @spec execute(EffectRequest.t(), keyword()) :: term()
  def execute(%EffectRequest{} = request, opts \\ []) do
    with :ok <- ConsequenceGate.admit(request.consequence) do
      reply =
        DispatcherFence.enter(fn ->
          AshA2A.Dispatcher.dispatch(
            request.skill.name,
            request.message,
            request.resource_or_domain,
            request.history,
            request.auth_identity,
            Keyword.put(opts, :resolved_skill, request.skill)
          )
        end)

      {Outcome.classify(reply), reply}
    end
  end
end
