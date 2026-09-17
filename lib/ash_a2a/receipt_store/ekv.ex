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
  `:in_flight` -- unless `AshA2A.ReceiptStore.ClaimLease` judges it abandoned
  (its configured lease has elapsed AND no `AshA2A.ReceiptOutbox` anchor
  exists for it), in which case it is reclaimed as a fresh claim. See
  `AshA2A.ReceiptStore.ClaimLease` for why this can never reclaim a claim
  that reached receipt preparation.

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

  alias AshA2A.{Actuation, Command, Identity, Receipt}
  alias AshA2A.ReceiptStore.ClaimLease

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
      entry -> decide_claim(name, key, entry, command)
    end
  end

  # Insert-if-absent CAS (`if_vsn: nil`) instead of an unconditional
  # `EKV.put/3` -- two concurrent claimants can both observe `EKV.get/2`
  # returning `nil` for the same fresh command_id, but only one `if_vsn: nil`
  # put can win. The loser re-reads whichever entry actually won and
  # re-dispatches through the exact same fingerprint-match logic
  # (`decide_claim/4`) a first-time reader would have used, instead of
  # trusting the not-found branch it already took.
  defp attempt_fresh_claim(name, key, command) do
    entry = fresh_claim_entry(command)

    case EKV.put(name, key, entry, if_vsn: nil) do
      {:ok, _vsn} ->
        {:execute, entry.execution_id}

      {:error, reason} when reason in [:conflict, :unconfirmed] ->
        case reread_after_cas(name, key, reason) do
          # The winning entry vanished between the lost race and this
          # re-read (for example a TTL/delete on that key) -- treat as
          # in-flight so the caller retries, rather than crash.
          nil ->
            {:error, :in_flight}

          # `:unconfirmed` means this very write may have committed. The
          # stored entry carrying this attempt's own execution id proves it
          # did: reporting a lost race here would leave the command claimed
          # with zero executors, forever `:in_flight` (RFC-SA2A-002 §71).
          %{execution_id: execution_id} when execution_id == entry.execution_id ->
            {:execute, entry.execution_id}

          winner ->
            decide_claim(name, key, winner, command)
        end
    end
  end

  # EKV's documented resolution for `:unconfirmed` is a consistent read of
  # the committed value; a plain `:conflict` keeps the local read.
  defp reread_after_cas(name, key, :unconfirmed), do: EKV.get(name, key, consistent: true)
  defp reread_after_cas(name, key, :conflict), do: EKV.get(name, key)

  defp decide_claim(
         _name,
         _key,
         %{fingerprint: fingerprint, receipt: %Receipt{} = receipt},
         %Command{} = command
       )
       when fingerprint == command.fingerprint do
    {:replay, Receipt.replay(receipt)}
  end

  # Bounded claim lease + reconciliation (closes the SA2A-CHAOS liveness
  # gap): a crash after `claim/2` durably records `receipt: nil` but before
  # a receipt anchor is ever prepared leaves no live executor to ever clear
  # it -- `{:error, :in_flight}` forever. `AshA2A.ReceiptStore.ClaimLease`
  # decides abandonment (lease elapsed AND no outbox anchor for this command
  # id); a claim that DID reach the outbox is never reclaimed regardless of
  # age. `reclaim/3` re-reads via `EKV.lookup/2` immediately before its own
  # `if_vsn:` write -- the same fresh CAS read-then-write discipline
  # `commit/2` already uses -- so a claimant that resumed and committed
  # between this decision and the write below loses the CAS and is replayed,
  # never double-executed.
  defp decide_claim(name, key, %{fingerprint: fingerprint} = entry, %Command{} = command)
       when fingerprint == command.fingerprint do
    if ClaimLease.abandoned?(Map.get(entry, :claimed_at), command.command_id) do
      reclaim(name, key, command)
    else
      {:error, :in_flight}
    end
  end

  defp decide_claim(_name, _key, _entry, _command) do
    {:error, :command_conflict}
  end

  defp reclaim(name, key, %Command{} = command) do
    case EKV.lookup(name, key) do
      {%{fingerprint: fingerprint, receipt: %Receipt{} = receipt}, _vsn}
      when fingerprint == command.fingerprint ->
        {:replay, Receipt.replay(receipt)}

      {%{fingerprint: fingerprint} = current, vsn} when fingerprint == command.fingerprint ->
        if ClaimLease.abandoned?(Map.get(current, :claimed_at), command.command_id) do
          entry = fresh_claim_entry(command)

          case EKV.put(name, key, entry, if_vsn: vsn) do
            {:ok, _new_vsn} ->
              {:execute, entry.execution_id}

            {:error, reason} when reason in [:conflict, :unconfirmed] ->
              case reread_after_cas(name, key, reason) do
                nil ->
                  {:error, :in_flight}

                %{execution_id: execution_id} when execution_id == entry.execution_id ->
                  {:execute, entry.execution_id}

                winner ->
                  decide_claim(name, key, winner, command)
              end
          end
        else
          {:error, :in_flight}
        end

      {%{}, _vsn} ->
        {:error, :command_conflict}

      nil ->
        attempt_fresh_claim(name, key, command)
    end
  end

  defp fresh_claim_entry(%Command{} = command) do
    %{
      fingerprint: command.fingerprint,
      execution_id: Identity.execution(Ash.UUIDv7.generate()),
      receipt: nil,
      claimed_at: ClaimLease.now()
    }
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

  @doc """
  RFC-SA2A-001 S55 actuation claim, cluster-wide.

  Uses the same insert-if-absent CAS (`if_vsn: nil`) discipline as `claim/2`:
  two nodes racing to actuate one effect can both read `nil`, but only one
  `if_vsn: nil` put wins. The loser re-reads whichever entry actually won and
  re-dispatches through the same decision logic, so it gets a real
  `{:duplicate, receipt}` or `:actuation_in_flight` rather than proceeding on
  the strength of its own stale read.
  """
  @impl true
  def claim_actuation(%Actuation{} = actuation, %Command{} = command, opts \\ []) do
    name = ekv_name(opts)
    key = actuation_key(actuation)

    case EKV.get(name, key) do
      nil -> attempt_fresh_actuation_claim(name, key, actuation, command)
      entry -> decide_actuation(entry, actuation)
    end
  end

  defp attempt_fresh_actuation_claim(name, key, actuation, command) do
    entry = %{
      idempotency_key: Identity.external(actuation.idempotency_key),
      command_id: Identity.external(command.command_id),
      receipt: nil
    }

    case EKV.put(name, key, entry, if_vsn: nil) do
      {:ok, _vsn} ->
        :proceed

      {:error, reason} when reason in [:conflict, :unconfirmed] ->
        case EKV.get(name, key) do
          nil -> {:error, :actuation_in_flight}
          winner -> decide_actuation(winner, actuation)
        end
    end
  end

  defp decide_actuation(%{idempotency_key: idempotency} = entry, %Actuation{} = actuation) do
    cond do
      idempotency != Identity.external(actuation.idempotency_key) ->
        {:error, :actuation_conflict}

      match?(%{receipt: %Receipt{}}, entry) ->
        {:duplicate, Receipt.replay(entry.receipt)}

      true ->
        {:error, :actuation_in_flight}
    end
  end

  defp decide_actuation(_entry, _actuation), do: {:error, :actuation_conflict}

  @impl true
  def commit_actuation(%Actuation{} = actuation, %Receipt{} = receipt, opts \\ []) do
    name = ekv_name(opts)
    key = actuation_key(actuation)

    case EKV.lookup(name, key) do
      {entry, vsn} when is_map(entry) ->
        case EKV.put(name, key, %{entry | receipt: receipt}, if_vsn: vsn) do
          {:ok, _new_vsn} ->
            :ok

          {:error, reason} when reason in [:conflict, :unconfirmed] ->
            {:error, :actuation_conflict}
        end

      _ ->
        {:error, :unclaimed_actuation}
    end
  end

  @impl true
  def release_actuation(%Actuation{} = actuation, opts \\ []) do
    name = ekv_name(opts)
    key = actuation_key(actuation)

    # Only an unexecuted claim is releasable -- see the same reasoning in
    # `AshA2A.ReceiptStore.Memory.handle_call({:release_actuation, ...})`.
    case EKV.lookup(name, key) do
      {%{receipt: nil}, vsn} -> release(name, key, vsn)
      _ -> :ok
    end
  end

  defp release(name, key, vsn) do
    if function_exported?(EKV, :delete, 3) do
      EKV.delete(name, key, if_vsn: vsn)
    else
      EKV.delete(name, key)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp actuation_key(%Actuation{actuation_id: actuation_id}),
    do: "actuation:" <> Identity.external(actuation_id)

  defp ekv_name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
