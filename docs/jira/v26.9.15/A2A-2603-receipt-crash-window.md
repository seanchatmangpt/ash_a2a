# A2A-2603 — Receipt crash-window verification

## Subject

Close the smallest remaining repository-native evidence gap after A2A-2601:
prove that a persisted pre-DO receipt anchor survives loss of the BEAM process
that performed an acknowledged external consequence, can be reconciled into a
fresh primary receipt store, and prevents replay from performing that external
consequence a second time.

## Falsifier

The claim fails if any of the following is observed:

1. the external receiver acknowledges the consequence but no pending receipt
   remains after the consequence-running BEAM dies;
2. a fresh primary store cannot reconcile the persisted pending anchor after
   the original in-memory claim disappears with that BEAM;
3. replay of the same command after reconciliation performs a second HTTP
   consequence;
4. the reconciled receipt invents a completed/failed outcome instead of
   preserving `status: :pending` uncertainty.

## Repository-native court

`test/ash_a2a_command_bus_crash_window_chicago_test.exs` starts a real local
Bandit receiver, launches `mix run` as a separate OS BEAM, executes a real
`:external_do` action that POSTs to the receiver, and kills its own process with
`:kill` only after the receiver acknowledges the POST. The parent test then
uses the same filesystem outbox from a different BEAM, starts a fresh primary
receipt store, reconciles the pending anchor, replays the exact command, and
requires the receiver's operation count to remain exactly one.

## Evidence boundary

Passing this court establishes process/BEAM-restart continuity for the
implemented host-local filesystem receipt journal plus loss/reconstruction of
an in-memory primary claim. It does not assert arbitrary external-system
transactional atomicity, filesystem durability across host power loss, shared
multi-host storage semantics, publication, production execution, or runtime
ALIVE standing.

A stronger deployment claim requires the intended production outbox volume and
external receiver to be exercised under real host/power-loss conditions, or an
external consequence protocol with command/receipt identity and deterministic
outcome reconciliation.
