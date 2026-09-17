defmodule AshA2A.ReceiptStore.ActuationClaimLease do
  @moduledoc """
  Bounded actuation (effect) claim liveness -- extends
  `AshA2A.ReceiptStore.ClaimLease`'s primary-command-claim liveness guarantee
  to RFC-SA2A-001 S55's second, effect-level index.

  `AshA2A.ReceiptStore.ClaimLease` already reclaims a crashed claimant's
  PRIMARY command-id claim once its lease elapses AND no
  `AshA2A.ReceiptOutbox` anchor exists for it -- otherwise every resubmission
  of that command id would hit `{:error, :in_flight}` forever. The S55
  actuation-claim index (`claim_actuation/3` / `decide_actuation/N`) had no
  equivalent: an in-flight actuation entry (`receipt: nil`) was refused
  forever until something explicitly called `release_actuation/2`, which
  `AshA2A.CommandBus.dispatch_actuation_claimed/9` only does on a clean
  receipt-anchor-prepare failure -- never on a genuine process crash mid-DO
  (`actuate/postcondition/commit_actuation` has no crash-safety net). RFC-
  SA2A-002 ARD §40's idempotency-store robustness requirement implicitly
  covers this second index too, not just the primary claim.

  This module reuses `ClaimLease`'s exact safety argument rather than
  inventing a second one: `claim_actuation/3` always runs strictly BEFORE
  `AshA2A.CommandBus.dispatch_actuation_claimed/9` prepares the receipt
  anchor for the SAME command id (see `AshA2A.CommandBus.run/4`'s claim
  order -- the actuation claim happens, then the anchor is prepared, then
  DO). So if that claimant's own PRIMARY command claim is itself abandoned
  per `ClaimLease.abandoned?/2` -- lease elapsed AND no outbox anchor exists
  for its `command_id` -- the anchor was never prepared, which means DO
  could not have started for this effect either, and the actuation claim is
  equally safe to reclaim.

  Two invariants fall out for free, without any new lease timer on the
  actuation entry itself:

    * An actuation entry that already carries a receipt never reaches this
      check -- callers route it to `{:duplicate, receipt}` first.
    * A primary claim that DID reach the outbox anchor is never judged
      abandoned by `ClaimLease`, so an actuation claim whose DO may already
      have started is never reclaimed here either -- the same "reached the
      outbox is never reclaimed" invariant `ClaimLease` documents for the
      primary claim carries over unchanged.

  A MISSING primary-claim record (no entry at all for the claimant's
  `command_id`) is deliberately NOT treated as abandoned, even though a
  missing entry can also arise from legitimate post-completion eviction --
  it is indistinguishable, from here, from a store queried out of band
  (directly, never through the primary claim path at all), and this module
  has no positive evidence DO never started in that case. Fail closed:
  refuse to reclaim rather than guess. The only two ways back for such an
  actuation remain the existing ones -- an explicit `release_actuation/2`,
  or `AshA2A.ReceiptOutbox.reconcile/2` / `AshA2A.Reconciliation.reconcile/4`.
  """

  alias AshA2A.Identity
  alias AshA2A.ReceiptStore.ClaimLease

  @doc """
  True when an in-flight actuation claim recorded against `command_id`
  (RFC-SA2A-001 S55's stored claimant) is abandoned and may be reclaimed by
  a fresh claimant.

  `primary_claim` is the raw primary command-claim entry the caller already
  read for `command_id` from the SAME store backend (a `Map.get/2` result
  for `AshA2A.ReceiptStore.Memory`, an `EKV.get/2` result for
  `AshA2A.ReceiptStore.Ekv`) -- `nil` when no such entry exists, which is
  treated as NOT abandoned (see the moduledoc's fail-closed rationale), not
  as proof of abandonment.
  """
  @spec abandoned?(map() | nil, Identity.t()) :: boolean()
  def abandoned?(nil, %Identity{kind: :command}), do: false

  def abandoned?(%{} = primary_claim, %Identity{kind: :command} = command_id) do
    ClaimLease.abandoned?(Map.get(primary_claim, :claimed_at), command_id)
  end
end
