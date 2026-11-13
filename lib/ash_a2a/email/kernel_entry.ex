# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Email.KernelEntry do
  @moduledoc """
  Default governed kernel entry for the email gateway (`AshA2A.Email.Plug`).

  `run/4` turns `(skill, input, resource, principal)` into a real `AshA2A.Command` and hands
  it to `AshA2A.CommandBus.run/4`, the only DO route. This module never calls
  `AshA2A.Dispatcher`.

  Authentication confers identity only. Authority is minted by
  `AshA2A.Authority.Grant.authorize/3` from the principal's LIVE standing grant at the
  configured broker; no grant means a typed `:email_no_live_grant` refusal before any
  command is built. `CommandBus` re-validates the grant against the broker immediately
  before DO. The command id is fresh per dispatch; effect-level dedup is the bus's
  actuation identity.

  `run/5` accepts `opts`: `:grant_opts` (passed to `Grant.authorize/3`, e.g. `:broker`),
  `:bus_opts` (passed to `CommandBus.run/4`, e.g. `:store_opts`).
  """

  alias AshA2A.{Authority.Grant, Command, CommandBus, Identity}
  alias AshA2A.Protocol.{Message, Part}

  @spec run(String.t(), map(), module(), map() | Identity.t() | String.t()) ::
          {:ok, AshA2A.Receipt.t()} | {:error, map()}
  def run(skill, input, resource, principal), do: run(skill, input, resource, principal, [])

  @spec run(String.t(), map(), module(), map() | Identity.t() | String.t(), keyword()) ::
          {:ok, AshA2A.Receipt.t()} | {:error, map()}
  def run(skill, input, resource, principal, opts) when is_binary(skill) do
    input = if is_map(input), do: input, else: %{}

    with {:ok, subject} <- subject(principal),
         {:ok, sk} <- resolve_skill(resource, skill),
         {:ok, authority} <- live_authority(subject.value, sk.id, Keyword.get(opts, :grant_opts, [])) do
      message = Message.new_user([Part.Data.new(input)])

      command =
        Command.new(sk.id,
          agent_id: to_string(resource),
          principal_id: subject,
          authority: authority,
          input: input,
          metadata: %{channel: :email}
        )

      CommandBus.run(command, message, resource, Keyword.get(opts, :bus_opts, []))
    end
  end

  defp subject(%Identity{kind: :principal} = id), do: {:ok, id}
  defp subject(%{id: id}) when is_binary(id) and id != "", do: {:ok, Identity.principal(id)}
  defp subject(id) when is_binary(id) and id != "", do: {:ok, Identity.principal(id)}

  defp subject(_),
    do: {:error, %{code: :email_no_live_grant, detail: "principal has no usable identity"}}

  defp resolve_skill(resource, skill) do
    case AshA2A.Info.skill(resource, skill) do
      {:ok, sk} -> {:ok, sk}
      _ -> {:error, %{code: :capability_not_found, detail: "capability_not_found"}}
    end
  end

  defp live_authority(subject, capability_id, grant_opts) do
    case Grant.authorize(subject, capability_id, grant_opts) do
      nil ->
        {:error,
         %{
           code: :email_no_live_grant,
           detail: "no standing grant for #{capability_id}; authentication confers no authority"
         }}

      authority ->
        {:ok, authority}
    end
  end
end
