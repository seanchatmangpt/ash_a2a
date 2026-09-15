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

  Unlike `AshA2A.ReceiptStore.Memory` (whose GenServer mailbox happens to
  serialize concurrent claims for free within one process), this module has
  no such free serialization -- so `claim/2` and `commit/2` use EKV's own
  per-key CAS (`if_vsn:`) to make the read-then-write atomic across
  concurrent claimants racing on the *same* command id, instead of a racy
  unconditional `EKV.get/2` + `EKV.put/3`. `claim/2`'s not-yet-claimed path
  inserts with `if_vsn: nil` (insert-if-absent); on `{:error, :conflict}` it
  re-reads whichever entry actually won the race and re-dispatches through
  the same fingerprint-match logic (replay / `:in_flight` / conflict) against
  that real entry, rather than trusting the branch already taken.
  `commit/2` re-reads the current version immediately before its own
  conditional `if_vsn:` write, so a stale write loses to `{:error,
  :unclaimed_command}` instead of silently overwriting a newer entry.
  Cross-node claim races are covered the same way, since EKV's CAS is
  cluster-wide, not process-local.
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
      nil -> attempt_fresh_claim(name, key, command)
      entry -> decide_claim(entry, command)
    end
  end

  # Insert-if-absent CAS (`if_vsn: nil`) instead of an unconditional
  # `EKV.put/3` -- two concurrent claimants can both observe `EKV.get/2`
  # returning `nil` for the same fresh command_id, but only one `if_vsn: nil`
  # put can win. The loser re-reads whichever entry actually won and
  # re-dispatches through the exact same fingerprint-match logic
  # (`decide_claim/2`) a first-time reader would have used, instead of
  # trusting the not-found branch it already took.
  defp attempt_fresh_claim(name, key, command) do
    execution_id = Identity.execution(Ash.UUIDv7.generate())
    entry = %{fingerprint: command.fingerprint, execution_id: execution_id, receipt: nil}

    case EKV.put(name, key, entry, if_vsn: nil) do
      {:ok, _vsn} ->
        {:execute, execution_id}

      {:error, reason} when reason in [:conflict, :unconfirmed] ->
        case EKV.get(name, key) do
          # The winning entry vanished between the lost race and this
          # re-read (for example a TTL/delete on that key) -- treat as
          # in-flight so the caller retries, rather than crash.
          nil -> {:error, :in_flight}
          entry -> decide_claim(entry, command)
        end
    end
  end

  defp decide_claim(
         %{fingerprint: fingerprint, receipt: %Receipt{} = receipt},
         %Command{} = command
       )
       when fingerprint == command.fingerprint do
    {:replay, Receipt.replay(receipt)}
  end

  defp decide_claim(%{fingerprint: fingerprint}, %Command{} = command)
       when fingerprint == command.fingerprint do
    {:error, :in_flight}
  end

  defp decide_claim(_entry, _command) do
    {:error, :command_conflict}
  end

  @impl true
  def commit(%Receipt{} = receipt, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(receipt.command_id)

    # `EKV.lookup/2` (not `EKV.get/2`) so the version read immediately before
    # this write is the exact version fed to `if_vsn:` below -- a fresh CAS
    # read-then-write pair, not the vsn from some earlier read (there is none
    # to thread through: `commit/2`'s signature is the `AshA2A.ReceiptStore`
    # behaviour contract, unchanged by this fix).
    case EKV.lookup(name, key) do
      {%{fingerprint: fingerprint} = entry, vsn} when fingerprint == receipt.fingerprint ->
        case EKV.put(name, key, %{entry | receipt: receipt}, if_vsn: vsn) do
          {:ok, _new_vsn} ->
            :ok

          {:error, reason} when reason in [:conflict, :unconfirmed] ->
            {:error, :unclaimed_command}
        end

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
