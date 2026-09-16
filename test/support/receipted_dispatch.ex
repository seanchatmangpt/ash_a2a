defmodule AshA2A.Test.ReceiptedDispatch do
  @moduledoc """
  Reaches `AshA2A.Dispatcher` for a consequence-bearing skill the one lawful
  way: through the real `AshA2A.CommandBus`.

  Since the sole-DO fence (`AshA2A.BrceAnchor`, RFC-SA2A-002 §38 Gate 7),
  `AshA2A.Dispatcher.dispatch/5` refuses a `:change`/`:external_do` skill that
  `AshA2A.CommandBus` did not anchor with a durable prepared receipt -- the
  `CHI-BRCE` court observed direct dispatch actuating unreceipted before that
  fence existed. Tests that qualify the dispatcher's own CRUD / primary-key /
  error-mapping mechanics on such skills therefore send a real
  `AshA2A.Command` carrying a matching real `AshA2A.Authority` through the
  real admission, claim, prepared-receipt anchor and commit, against the real
  default receipt store, and get back the exact reply the dispatcher produced
  (`AshA2A.Receipt.reply`). Nothing is stubbed; dispatcher-mechanics
  assertions stay unchanged.
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, Receipt}

  @spec dispatch(atom() | String.t(), A2A.Message.t(), module(), [A2A.Message.t()], term()) ::
          AshA2A.Dispatcher.reply()
  def dispatch(skill_name, message, resource_or_domain, history \\ [], auth_identity \\ nil) do
    capability_id = to_string(skill_name)
    principal = Identity.principal("receipted-dispatch-test")
    {:ok, input} = AshA2A.Dispatcher.fetch_input(message)

    command =
      Command.new(capability_id,
        command_id: "receipted-dispatch-" <> Ash.UUIDv7.generate(),
        agent_id: inspect(resource_or_domain),
        principal_id: principal,
        authority: Authority.new(principal, capability_id),
        input: input
      )

    case CommandBus.run(command, message, resource_or_domain,
           history: history,
           auth_identity: auth_identity
         ) do
      {:ok, %Receipt{reply: reply}} -> reply
      {:error, reason} -> {:error, reason}
    end
  end
end
