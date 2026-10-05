# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
  unchanged by this module.

  The anchor test is `AshA2A.ReceiptOutbox.anchored_command?/1`: journal
  files are keyed by a digest of the command id, so the check is one
  directory listing plus a prefix match -- no decoding -- and a torn
  (unreadable) journal file blocks reclaim only for its OWN command id. A
  legacy-named (pre-command-keyed) entry is decoded; an unreadable legacy
  entry still blocks every reclaim (fail closed), which is why
  `AshA2A.ReceiptOutbox.Reconciler` migrates legacy entries on start.

  The lease is injectable per call (`opts[:claim_lease_ms]`, falling back to
  `config :ash_a2a, :claim_lease_ms`), so a caller or test never needs to
  mutate global application env to pin it.
  """

  alias AshA2A.{Identity, ReceiptOutbox}

  @default_lease_ms 300_000

  @doc """
  The configured claim lease in milliseconds:
  `config :ash_a2a, :claim_lease_ms`, default #{@default_lease_ms}.
  `duration_ms/1` layers the per-call `opts[:claim_lease_ms]` override on
  top of this value.
  """
  @spec lease_ms() :: non_neg_integer()
  def lease_ms, do: Application.get_env(:ash_a2a, :claim_lease_ms, @default_lease_ms)

  @doc """
  The claim lease duration in milliseconds: `opts[:claim_lease_ms]` when
  given, else `lease_ms/0` (`config :ash_a2a, :claim_lease_ms`, else
  #{300_000}).
  """
  @spec duration_ms(keyword()) :: non_neg_integer()
  def duration_ms(opts \\ []) do
    Keyword.get(opts, :claim_lease_ms) || lease_ms()
  end

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
  @spec abandoned?(DateTime.t() | nil, Identity.t(), keyword()) :: boolean()
  def abandoned?(claimed_at, %Identity{kind: :command} = command_id, opts \\ []) do
    lease_elapsed?(claimed_at, opts) and not ReceiptOutbox.anchored_command?(command_id)
  end

  defp lease_elapsed?(nil, _opts), do: true

  defp lease_elapsed?(%DateTime{} = claimed_at, opts) do
    DateTime.diff(now(), claimed_at, :millisecond) >= duration_ms(opts)
  end
end
