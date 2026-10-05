# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.Governed do
  @moduledoc """
  Test helpers for application developers: dispatch through the REAL
  `AshA2A.CommandBus` with a REAL in-process authority broker and receipt
  store -- no mocks, no Postgres, no Repo/Oban.

  Every collaborator is the production module: `AshA2A.ReceiptStore.Memory`
  (a `GenServer`) and `AshA2A.Authority.Broker.InMemory` (a `GenServer`
  holding real issued/revoked state). Both are started uniquely named under
  the caller's ExUnit supervisor, so tests using this module are safe with
  `async: true`. Assertions are on state: the returned receipt, the stored
  receipt, and the effects your own action bodies really performed.

      setup do
        %{gov: AshA2A.Test.Governed.start!()}
      end

      test "create needs a grant", %{gov: gov} do
        assert {:error, %{code: :authority_required}} =
                 AshA2A.Test.Governed.run(gov, MyApp.Item, "MyApp.Item.create",
                   principal: "alice", input: %{label: "x"})

        gov = AshA2A.Test.Governed.grant!(gov, "alice", "MyApp.Item.create")
        assert {:ok, %{status: :completed}} =
                 AshA2A.Test.Governed.run(gov, MyApp.Item, "MyApp.Item.create",
                   principal: "alice", input: %{label: "x"})
      end

  `:observe` skills need no grant. `:change` and `:external_do` skills need a
  standing grant (RFC-SA2A-001 S29); the pre-DO gate revalidates it against
  THIS context's broker immediately before actuation (RFC-SA2A-004 S10).
  """

  alias AshA2A.{Authority, Command, CommandBus, Identity, ReceiptStore}
  alias AshA2A.Authority.Broker.InMemory

  defstruct [:store_opts, :broker_opts, :agent_id, issued: MapSet.new()]

  @type t :: %__MODULE__{
          store_opts: keyword(),
          broker_opts: keyword(),
          agent_id: String.t(),
          issued: MapSet.t()
        }

  @doc """
  Starts a fresh receipt store and authority broker (uniquely named, under the
  test supervisor via `ExUnit.Callbacks.start_supervised!/1`) and returns the
  governed context. Call it from `setup`/a test body.
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    uniq = System.unique_integer([:positive])
    store_name = Module.concat(__MODULE__, "Store#{uniq}")
    broker_name = Module.concat(__MODULE__, "Broker#{uniq}")

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({ReceiptStore.Memory, name: store_name}, id: store_name)
    )

    ExUnit.Callbacks.start_supervised!(%{
      id: broker_name,
      start: {InMemory, :start_link, [[name: broker_name]]}
    })

    %__MODULE__{
      store_opts: [name: store_name],
      broker_opts: [name: broker_name],
      agent_id: Keyword.get(opts, :agent_id, "governed-test-agent")
    }
  end

  @doc """
  Issues a real standing grant for `principal` on `capability_id` through the
  context's broker and returns the updated context (rebind it: `gov =
  grant!(gov, ...)`). Re-granting a pair that
  already stands is a no-op. The post-condition is read back from the broker.
  """
  @spec grant!(t(), term(), String.t()) :: t()
  def grant!(%__MODULE__{} = gov, principal, capability_id) when is_binary(capability_id) do
    subject = Identity.principal(principal)

    case InMemory.issue(
           subject,
           capability_id,
           gov.broker_opts ++ [token_id: Authority.grant_token_id(subject, capability_id)]
         ) do
      {:ok, %Authority{}} -> :ok
      {:error, %{reason: :token_id_taken}} -> :ok
    end

    true = InMemory.granted?(subject, capability_id, gov.broker_opts)
    %{gov | issued: MapSet.put(gov.issued, {subject, capability_id})}
  end

  @doc """
  Revokes a previously issued grant so a test can assert the pre-DO
  revalidation refuses (`:authority_revoked`).
  """
  @spec revoke!(t(), term(), String.t()) :: t()
  def revoke!(%__MODULE__{} = gov, principal, capability_id) do
    subject = Identity.principal(principal)

    authority =
      Authority.new(subject, capability_id,
        token_id: Authority.grant_token_id(subject, capability_id)
      )

    :ok = InMemory.revoke(authority, gov.broker_opts)
    gov
  end

  @doc """
  Builds a command and dispatches it through `AshA2A.CommandBus.run/4`.

  Options: `:principal` (default `"anonymous"`), `:input` (default `%{}`),
  `:command_id` (default unique), plus any other `CommandBus.run/4` option
  (e.g. `:actuation_dedup`, `:capability_release_closure`). For a
  consequential capability the authority is admitted from the context's
  broker when a grant was issued through this context (even if since revoked,
  so the pre-DO revalidation refuses `:authority_revoked`); with no grant
  ever issued no authority is attached and the bus refuses
  `:authority_required`.
  """
  @spec run(t(), module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = gov, resource_or_domain, capability_id, opts \\ []) do
    {principal, opts} = Keyword.pop(opts, :principal, "anonymous")
    {input, opts} = Keyword.pop(opts, :input, %{})

    {command_id, opts} =
      Keyword.pop(opts, :command_id, "gov-#{System.unique_integer([:positive])}")

    subject = Identity.principal(principal)

    authority =
      if MapSet.member?(gov.issued, {subject, capability_id}) do
        Authority.new(subject, capability_id,
          token_id: Authority.grant_token_id(subject, capability_id),
          admitted_by: nil
        )
        |> Map.put(:admitted_by, {InMemory, gov.broker_opts})
        |> Map.put(:source, :transport_verified)
      end

    command =
      Command.new(capability_id,
        command_id: command_id,
        agent_id: gov.agent_id,
        principal_id: subject,
        authority: authority,
        input: input
      )

    CommandBus.run(
      command,
      AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(stringify(input))]),
      resource_or_domain,
      Keyword.merge(
        [store_opts: gov.store_opts, authority_broker: {InMemory, gov.broker_opts}],
        opts
      )
    )
  end

  @doc "Fetches the receipt the context's store committed for `command_id`."
  @spec fetch_receipt(t(), Identity.t() | String.t()) :: {:ok, map()} | :error
  def fetch_receipt(%__MODULE__{} = gov, command_id),
    do: ReceiptStore.Memory.fetch(command_id, gov.store_opts)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
