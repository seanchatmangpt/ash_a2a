# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

  An in-flight actuation (effect) claim is reclaimed the same way as the
  primary command claim: see `AshA2A.ReceiptStore.ActuationClaimLease` for
  why deferring to the claimant's own primary command claim's
  `ClaimLease.abandoned?/2` verdict is a sound liveness guarantee one layer
  down from the primary claim.

  ## Fencing and error totality (findings R4, R8)

  `commit/2` requires the stored claim's `execution_id` to equal the
  receipt's (`{:error, :stale_execution}` otherwise), and `confirm_claim/3`
  lets `AshA2A.CommandBus` re-check ownership before DO. An `:unconfirmed`
  EKV write is settled by a consistent read: `:ok` only when the stored value
  is exactly what this call wrote, `{:error, :receipt_store_unconfirmed}`
  otherwise -- never reported as `:unclaimed_command`. Any other EKV error
  maps to the typed `:receipt_store_unavailable` /
  `:actuation_store_unavailable` instead of raising `CaseClauseError`.
  """

  @behaviour AshA2A.ReceiptStore

  alias AshA2A.{Actuation, Command, Identity, Receipt}
  alias AshA2A.ReceiptStore.{ActuationClaimLease, ClaimLease}

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

  @doc false
  # S42 totality for the typed codes this store returns.
  def __sa2a_refusal_codes__ do
    %{
      stale_execution: :refused_identity,
      receipt_store_unconfirmed: :blocked_resource
    }
  end

  @impl true
  def claim(%Command{} = command, opts \\ []) do
    name = ekv_name(opts)
    key = Identity.external(command.command_id)
    lease = Keyword.take(opts, [:claim_lease_ms, :execution_id])

    case EKV.get(name, key) do
      nil -> attempt_fresh_claim(name, key, command, lease)
      entry -> decide_claim(name, key, entry, command, lease)
    end
  end

  # Insert-if-absent CAS (`if_vsn: nil`) instead of an unconditional
  # `EKV.put/3` -- two concurrent claimants can both observe `EKV.get/2`
  # returning `nil` for the same fresh command_id, but only one `if_vsn: nil`
  # put can win. The loser re-reads whichever entry actually won and
  # re-dispatches through the exact same fingerprint-match logic
  # (`decide_claim/4`) a first-time reader would have used, instead of
  # trusting the not-found branch it already took.
  defp attempt_fresh_claim(name, key, command, lease) do
    entry = fresh_claim_entry(command, lease)

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
            decide_claim(name, key, winner, command, lease)
        end

      {:error, _other} ->
        {:error, :receipt_store_unavailable}
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
         %Command{} = command,
         _lease
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
  defp decide_claim(name, key, %{fingerprint: fingerprint} = entry, %Command{} = command, lease)
       when fingerprint == command.fingerprint do
    if ClaimLease.abandoned?(Map.get(entry, :claimed_at), command.command_id, lease) do
      reclaim(name, key, command, lease)
    else
      {:error, :in_flight}
    end
  end

  defp decide_claim(_name, _key, _entry, _command, _lease) do
    {:error, :command_conflict}
  end

  defp reclaim(name, key, %Command{} = command, lease) do
    case EKV.lookup(name, key) do
      {%{fingerprint: fingerprint, receipt: %Receipt{} = receipt}, _vsn}
      when fingerprint == command.fingerprint ->
        {:replay, Receipt.replay(receipt)}

      {%{fingerprint: fingerprint} = current, vsn} when fingerprint == command.fingerprint ->
        if ClaimLease.abandoned?(Map.get(current, :claimed_at), command.command_id, lease) do
          entry = fresh_claim_entry(command, lease)

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
                  decide_claim(name, key, winner, command, lease)
              end

            {:error, _other} ->
              {:error, :receipt_store_unavailable}
          end
        else
          {:error, :in_flight}
        end

      {%{}, _vsn} ->
        {:error, :command_conflict}

      nil ->
        attempt_fresh_claim(name, key, command, lease)
    end
  end

  # `opts[:execution_id]`: see `AshA2A.ReceiptStore.Memory`'s identical
  # option -- reconciliation re-creates a lost claim under the outboxed
  # receipt's own execution id.
  defp fresh_claim_entry(%Command{} = command, opts) do
    %{
      fingerprint: command.fingerprint,
      execution_id:
        case Keyword.get(opts, :execution_id) do
          %Identity{kind: :execution} = given -> given
          _ -> Identity.execution(Ash.UUIDv7.generate())
        end,
      receipt: nil,
      claimed_at: ClaimLease.now()
    }
  end

  @impl true
  def commit(%Receipt{} = receipt, opts \\ []) do
    commit_attempt(ekv_name(opts), Identity.external(receipt.command_id), receipt, 3)
  end

  # `EKV.lookup/2` (not `EKV.get/2`) so the version read immediately before
  # each write is the exact version fed to `if_vsn:` -- a fresh CAS
  # read-then-write pair. A lost CAS re-reads and re-decides (bounded), so a
  # concurrent writer of an unrelated field never turns a legitimate commit
  # into a false `:unclaimed_command`.
  defp commit_attempt(_name, _key, _receipt, 0), do: {:error, :receipt_store_unavailable}

  defp commit_attempt(name, key, %Receipt{} = receipt, attempts) do
    case EKV.lookup(name, key) do
      {%{fingerprint: fingerprint} = entry, vsn} when fingerprint == receipt.fingerprint ->
        # Execution-id fencing (finding R4).
        if Map.get(entry, :execution_id) == receipt.execution_id do
          next = %{entry | receipt: receipt}

          case EKV.put(name, key, next, if_vsn: vsn) do
            {:ok, _new_vsn} -> :ok
            {:error, :conflict} -> commit_attempt(name, key, receipt, attempts - 1)
            {:error, :unconfirmed} -> settle(name, key, next)
            {:error, _other} -> {:error, :receipt_store_unavailable}
          end
        else
          {:error, :stale_execution}
        end

      _ ->
        {:error, :unclaimed_command}
    end
  end

  @doc """
  Confirms `execution_id` still owns the claim for `command_id` (finding R4),
  via a consistent (quorum) read. `{:error, :stale_execution}` when another
  execution holds it.
  """
  @impl true
  @spec confirm_claim(Identity.t(), Identity.t(), keyword()) ::
          :ok | {:error, :stale_execution | :receipt_store_unavailable}
  def confirm_claim(
        %Identity{kind: :command} = command_id,
        %Identity{} = execution_id,
        opts \\ []
      ) do
    case consistent_get(ekv_name(opts), Identity.external(command_id)) do
      {:ok, %{execution_id: ^execution_id}} -> :ok
      {:ok, %{}} -> {:error, :stale_execution}
      {:ok, nil} -> {:error, :stale_execution}
      {:error, _reason} -> {:error, :receipt_store_unavailable}
    end
  end

  # `EKV.get(name, key, consistent: true)` RAISES when the consensus read
  # fails (no quorum, no CAS config) -- it never returns `{:error, _}`. This
  # wrapper makes the fencing and settle paths total: a failed consistent
  # read is a typed unavailability, never an exception escaping the store.
  defp consistent_get(name, key) do
    {:ok, EKV.get(name, key, consistent: true)}
  rescue
    error -> {:error, {:consistent_read_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:consistent_read_failed, reason}}
  end

  # EKV's documented resolution for an `:unconfirmed` write is a consistent
  # read: the write landed iff the committed value is exactly what we wrote
  # (finding R8 -- previously misreported as `:unclaimed_command`, which sent
  # `AshA2A.ReceiptOutbox` into a spurious re-claim).
  defp settle(name, key, expected) do
    case consistent_get(name, key) do
      {:ok, ^expected} -> :ok
      _other -> {:error, :receipt_store_unconfirmed}
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
    lease = lease_opts(opts)

    case EKV.get(name, key) do
      nil -> attempt_fresh_actuation_claim(name, key, actuation, command, lease)
      entry -> decide_actuation(name, entry, actuation, command, lease)
    end
  end

  defp attempt_fresh_actuation_claim(name, key, actuation, command, lease) do
    entry = %{
      idempotency_key: Identity.external(actuation.idempotency_key),
      command_id: command.command_id,
      receipt: nil
    }

    case EKV.put(name, key, entry, if_vsn: nil) do
      {:ok, _vsn} ->
        :proceed

      {:error, :unconfirmed} ->
        case EKV.get(name, key, consistent: true) do
          ^entry -> :proceed
          nil -> {:error, :actuation_in_flight}
          winner -> decide_actuation(name, winner, actuation, command, lease)
        end

      {:error, :conflict} ->
        case EKV.get(name, key) do
          nil -> {:error, :actuation_in_flight}
          winner -> decide_actuation(name, winner, actuation, command, lease)
        end

      {:error, _other} ->
        {:error, :actuation_store_unavailable}
    end
  end

  defp decide_actuation(
         name,
         %{idempotency_key: idempotency} = entry,
         %Actuation{} = actuation,
         %Command{} = command,
         lease
       ) do
    cond do
      idempotency != Identity.external(actuation.idempotency_key) ->
        {:error, :actuation_conflict}

      match?(%{receipt: %Receipt{}}, entry) ->
        {:duplicate, Receipt.replay(entry.receipt)}

      true ->
        reclaim_or_refuse_actuation(name, entry, actuation, command, lease)
    end
  end

  defp decide_actuation(_name, _entry, _actuation, _command, _lease),
    do: {:error, :actuation_conflict}

  # Bounded actuation-claim lease + reconciliation (RFC-SA2A-001 S55, ARD S40's
  # idempotency-store liveness requirement, one index below the primary
  # command claim). `claim_actuation/3` always runs before this claimant's own
  # receipt-anchor prepare, so if ITS primary command claim is abandoned per
  # `ClaimLease.abandoned?/2`, DO never started for this effect either -- see
  # `AshA2A.ReceiptStore.ActuationClaimLease` for the full argument and why a
  # claim that DID reach the outbox is still never reclaimed.
  #
  # A claimant whose primary claim already carries a finalized receipt is a
  # completed effect whose actuation-index commit was lost (finding R1): the
  # primary receipt is returned as the duplicate and written back into the
  # actuation entry, never re-run.
  defp reclaim_or_refuse_actuation(
         name,
         %{command_id: claimant_command_id},
         actuation,
         command,
         lease
       ) do
    primary_claim = EKV.get(name, Identity.external(claimant_command_id))

    case ActuationClaimLease.decide(primary_claim, claimant_command_id, lease) do
      :reclaim ->
        reclaim_actuation(name, actuation, command, lease)

      {:duplicate, %Receipt{} = receipt} ->
        heal_actuation(name, actuation, receipt)
        {:duplicate, Receipt.replay(receipt)}

      :in_flight ->
        {:error, :actuation_in_flight}
    end
  end

  # Best-effort: the duplicate answer is already correct without it; the heal
  # only saves the next claimant the primary-claim read.
  defp heal_actuation(name, actuation, receipt) do
    key = actuation_key(actuation)

    case EKV.lookup(name, key) do
      {%{receipt: nil} = entry, vsn} ->
        EKV.put(name, key, %{entry | receipt: receipt}, if_vsn: vsn)

      _ ->
        :ok
    end

    :ok
  rescue
    _error -> :ok
  end

  # Fresh CAS read-then-write immediately before the reclaiming write, the
  # same discipline `reclaim/3` already uses for the primary claim: a
  # claimant that committed between the abandonment decision and this write
  # loses the CAS and is re-dispatched through `decide_actuation/4` against
  # the real winning entry, never silently overwritten.
  defp reclaim_actuation(name, %Actuation{} = actuation, %Command{} = command, lease) do
    key = actuation_key(actuation)

    case EKV.lookup(name, key) do
      {%{receipt: %Receipt{}} = current, _vsn} ->
        {:duplicate, Receipt.replay(current.receipt)}

      {current, vsn} when is_map(current) ->
        fresh = %{current | command_id: command.command_id, receipt: nil}

        case EKV.put(name, key, fresh, if_vsn: vsn) do
          {:ok, _new_vsn} ->
            :proceed

          {:error, :unconfirmed} ->
            case EKV.get(name, key, consistent: true) do
              ^fresh -> :proceed
              nil -> {:error, :actuation_in_flight}
              winner -> decide_actuation(name, winner, actuation, command, lease)
            end

          {:error, :conflict} ->
            case EKV.get(name, key) do
              nil -> {:error, :actuation_in_flight}
              winner -> decide_actuation(name, winner, actuation, command, lease)
            end

          {:error, _other} ->
            {:error, :actuation_store_unavailable}
        end

      nil ->
        attempt_fresh_actuation_claim(name, key, actuation, command, lease)
    end
  end

  @impl true
  def commit_actuation(%Actuation{} = actuation, %Receipt{} = receipt, opts \\ []) do
    name = ekv_name(opts)
    key = actuation_key(actuation)

    case EKV.lookup(name, key) do
      {entry, vsn} when is_map(entry) ->
        next = %{entry | receipt: receipt}

        case EKV.put(name, key, next, if_vsn: vsn) do
          {:ok, _new_vsn} -> :ok
          {:error, :conflict} -> {:error, :actuation_conflict}
          {:error, :unconfirmed} -> settle(name, key, next)
          {:error, _other} -> {:error, :actuation_store_unavailable}
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

  defp lease_opts(opts), do: Keyword.take(opts, [:claim_lease_ms])
end
