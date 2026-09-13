defmodule AshA2A.CommandBus do
  @moduledoc """
  Canonical receipted route from an admitted `AshA2A.Command` to the existing
  Ash dispatcher. Planning and provider adapters may call this module; they do
  not bypass its capability, identity, replay, or evidence checks.
  """

  alias AshA2A.{Authority, Command, Identity, Receipt}

  @type result :: {:ok, Receipt.t()} | {:error, map()}

  @spec run(Command.t(), A2A.Message.t(), module(), keyword()) :: result()
  def run(%Command{} = command, %A2A.Message{} = message, resource_or_domain, opts \\ []) do
    store =
      Keyword.get(
        opts,
        :store,
        Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory)
      )

    store_opts = Keyword.get(opts, :store_opts, [])

    with {:ok, skill, action, consequence} <- inspect_target(command, resource_or_domain),
         :ok <- admit(command, consequence),
         claim <- store.claim(command, store_opts) do
      case claim do
        {:replay, receipt} ->
          {:ok, receipt}

        {:execute, %Identity{kind: :execution} = execution_id} ->
          reply =
            AshA2A.Dispatcher.dispatch(
              skill.name,
              message,
              resource_or_domain,
              Keyword.get(opts, :history, []),
              Keyword.get(opts, :auth_identity)
            )

          receipt = Receipt.from_reply(command, execution_id, consequence, reply)
          :ok = store.commit(receipt, store_opts)
          emit_receipt(receipt)
          {:ok, receipt}

        {:error, reason} ->
          {:error, refusal(reason)}
      end
    end
  end

  defp inspect_target(command, resource_or_domain) do
    with {:ok, skill} <- AshA2A.Info.skill(resource_or_domain, command.capability_id),
         action when not is_nil(action) <- Ash.Resource.Info.action(skill.resource, skill.action) do
      consequence = if action.type == :read, do: :observe, else: :change
      {:ok, skill, action, consequence}
    else
      {:error, :skill_not_found} -> {:error, refusal(:capability_not_found)}
      nil -> {:error, refusal(:action_not_found)}
    end
  end

  defp admit(_command, :observe), do: :ok

  defp admit(%Command{authority: %Authority{} = authority} = command, :change) do
    if Authority.admits?(authority, command),
      do: :ok,
      else: {:error, refusal(:authority_mismatch)}
  end

  defp admit(_command, :change), do: {:error, refusal(:authority_required)}

  defp refusal(reason), do: %{code: reason, detail: Atom.to_string(reason)}

  defp emit_receipt(receipt) do
    :telemetry.execute([:ash_a2a, :receipt, :committed], %{}, %{receipt: receipt})
  end
end
