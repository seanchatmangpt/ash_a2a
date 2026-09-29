defmodule AshA2A.ConsequenceKernel.W4.DispatchInversion do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.W4.{ConsequenceGate, DispatcherFence, EffectRequest, Outcome}
  @spec execute(EffectRequest.t(), keyword()) :: term()
  def execute(request, opts \\ [])

  # An observation is not a consequence: it never needs the kernel, but the CommandBus still
  # routes it through here so every dispatch shares one entry. It takes the explicit
  # observation-only dispatcher entry, whose sole-DO anchor gate refuses it if the resolved
  # skill is in fact consequence-bearing.
  def execute(%EffectRequest{consequence: :observe} = request, opts) do
    reply =
      AshA2A.Dispatcher.dispatch_observe(
        request.skill.name,
        request.message,
        request.resource_or_domain,
        request.history,
        request.auth_identity,
        Keyword.put(opts, :resolved_skill, request.skill)
      )

    {Outcome.classify(reply), reply}
  end

  def execute(%EffectRequest{} = request, opts) do
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
