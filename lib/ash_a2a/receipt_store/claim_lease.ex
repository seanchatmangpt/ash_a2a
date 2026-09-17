defmodule AshA2A.ReceiptStore.ClaimLease do
  @moduledoc """
  Bounded claim lease + reconciliation, shared by `AshA2A.ReceiptStore.Memory`
  and `AshA2A.ReceiptStore.Ekv`.

  Closes a real SA2A-CHAOS liveness gap: `ReceiptStore.claim/2` durably
  records `receipt: nil` before any receipt anchor exists. If the claiming
  process crashes before `CommandBus.prepare_receipt_anchor/4` ever runs
  (RFC-SA2A-002 §38's own pre-DO boundary), no live executor remains to ever
  set `receipt`, and every resubmission of that command id hits
  `{:error, :in_flight}` forever -- a liveness bug, not a safety violation
  (RFC-SA2A-002 §70/§71 govern at-most-once dispatch, never eventual
  resubmission).

  An in-flight claim (`receipt: nil`, matching fingerprint) becomes
  reclaimable only when BOTH hold:

    * the configured lease (`Application.get_env(:ash_a2a, :claim_lease_ms)`,
      default #{inspect(300_000)}ms) has elapsed since the entry's
      `claimed_at`;
    * `AshA2A.ReceiptOutbox` holds no anchor (`:pending` or finalized, readable
      or not yet drained) for this command id -- i.e. the claimant never
      reached the pre-DO receipt boundary, so DO cannot have started.

  A claim that DID reach the outbox is NEVER reclaimed by lease expiry alone,
  no matter how old it is -- it may already have actuated, and reclaiming it
  would violate BRCE's at-most-once guarantee. Its only recovery path remains
  `AshA2A.ReceiptOutbox.reconcile/2` / `AshA2A.Reconciliation.reconcile/4`,
  unchanged by this module. A present-but-unreadable (torn) outbox entry
  counts as an anchor too: `ReceiptOutbox.entries/0` only returns decodable
  entries, so this module counts raw journal files
  (`AshA2A.ReceiptOutbox.count/0` vs. `entries/0`) rather than trusting
  decodability, the same fail-closed instinct `AshA2A.Reconciliation` already
  applies to unreadable entries.
  """

  alias AshA2A.{Identity, ReceiptOutbox}

  @default_lease_ms 300_000

  @doc "The configured claim lease duration in milliseconds."
  @spec duration_ms() :: non_neg_integer()
  def duration_ms, do: Application.get_env(:ash_a2a, :claim_lease_ms, @default_lease_ms)

  @doc "Wall-clock reading to stamp a fresh (or reclaimed) claim's `claimed_at` with."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @doc """
  True when an in-flight claim for `command_id` claimed at `claimed_at` is
  abandoned: the lease has elapsed and no outbox anchor exists for this
  command id. A `nil` `claimed_at` (an entry claimed before this field
  existed, e.g. written by a pre-upgrade node) is treated as already
  lease-expired -- it predates lease tracking and so cannot itself be
  evidence of a live executor; the anchor check still applies.
  """
  @spec abandoned?(DateTime.t() | nil, Identity.t()) :: boolean()
  def abandoned?(claimed_at, %Identity{kind: :command} = command_id) do
    lease_elapsed?(claimed_at) and not anchored?(command_id)
  end

  defp lease_elapsed?(nil), do: true

  defp lease_elapsed?(%DateTime{} = claimed_at) do
    DateTime.diff(now(), claimed_at, :millisecond) >= duration_ms()
  end

  # Raw entry count vs. readable entries: an unreadable (torn) journal file
  # for this command id must still block reclaim, the same fail-closed
  # instinct `AshA2A.Reconciliation.classify/4` already applies -- a torn
  # file could be the very anchor that proves DO started.
  defp anchored?(%Identity{} = command_id) do
    readable = ReceiptOutbox.entries()
    unreadable = max(ReceiptOutbox.count() - length(readable), 0)

    unreadable > 0 or Enum.any?(readable, &(&1.command_id == command_id))
  end
end
