defmodule AshA2A.ReceiptStore.Ekv do
  @moduledoc """
  EKV-backed durable receipt store.

  Persists command claim/commit state to a real on-disk `EKV` instance
  (`:ekv`, hex `~> 0.4`), so a receipt survives process and node restarts --
  unlike `AshA2A.ReceiptStore.Memory`'s in-process `Map`. `EKV` itself must
  already be started and supervised under the configured `:name` (see
  `AshA2A.Application.receipt_store_children/0`, which wires this up
  automatically when `:ash_a2a, :receipt_store` is configured as this
  module -- or start `EKV` manually and pass `name:` in `opts`/`store_opts`
  to `claim/2`, `commit/2`, and `fetch/2`).

  Claim/commit decision logic mirrors `AshA2A.ReceiptStore.Memory`'s
  `handle_call` clauses exactly: same command id + same fingerprint replays
  the already-committed receipt; same id + different fingerprint is a
  `:command_conflict`; a claimed-but-not-yet-committed command is
  `:in_flight`.

  Like `AshA2A.ReceiptStore.Memory` (whose GenServer mailbox happens to
  serialize concurrent claims for free within one process), this module does
  not use EKV's CAS (`if_vsn:`) surface to make claim/commit atomic across
  concurrent claimants racing on the *same* command id -- it replicates
  Memory's decision *logic* against real durable storage, not a distributed
  locking protocol. Cross-process/cross-node claim races on one command id
  are a genuinely different problem, out of this module's scope; EKV's CAS
  API (`if_vsn:`, `update/4`) is available should a host need that later.
  """

  @behaviour AshA2A.ReceiptStore

  alias AshA2A.{Command, Identity, Receipt}

  @doc """
  Declares this store genuinely durable.

  `AshA2A.CommandBus.run/4` checks for this function via
  `Code.ensure_loaded?/1` + `function_exported?/3` -- the same idiom already
  used by `AshA2A.Durability.DurableServer`'s provider dispatch and
  `AshA2A.Execution.FLAME.available?/0` -- rather than a hardcoded module
  allowlist, so any store module may opt in to `standing: :durable` the same
  way.
  """
  @spec durable?() :: boolean()
  def durable?, do: true

  @impl true
  def claim(%Command{} = command, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(command.command_id)

    case EKV.get(name, key) do
      nil ->
        execution_id = Identity.execution(Ash.UUIDv7.generate())
        entry = %{fingerprint: command.fingerprint, execution_id: execution_id, receipt: nil}
        :ok = EKV.put(name, key, entry)
        {:execute, execution_id}

      %{fingerprint: fingerprint, receipt: %Receipt{} = receipt}
      when fingerprint == command.fingerprint ->
        {:replay, Receipt.replay(receipt)}

      %{fingerprint: fingerprint} when fingerprint == command.fingerprint ->
        {:error, :in_flight}

      _ ->
        {:error, :command_conflict}
    end
  end

  @impl true
  def commit(%Receipt{} = receipt, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(receipt.command_id)

    case EKV.get(name, key) do
      %{fingerprint: fingerprint} = entry when fingerprint == receipt.fingerprint ->
        :ok = EKV.put(name, key, %{entry | receipt: receipt})
        :ok

      _ ->
        {:error, :unclaimed_command}
    end
  end

  @impl true
  def fetch(%Identity{kind: :command} = command_id, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(command_id)

    case EKV.get(name, key) do
      %{receipt: %Receipt{} = receipt} -> {:ok, receipt}
      _ -> :error
    end
  end

  defp ekv_name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
