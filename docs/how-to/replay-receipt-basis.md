# Replay a receipt basis (without re-actuating)

Reconstruct the semantic basis of an execution from its CommandBus receipt.
This is RFC-SA2A-001 S32 (`AshA2A.Receipt.Replay`). Replaying evidence is
not authority to re-actuate.

## Contents

1. Call `Receipt.Replay.basis/1`
2. Refuse to re-actuate from the replayed authority
3. See Also

## 1. Call `Receipt.Replay.basis/1`

```elixir
alias AshA2A.Receipt.Replay

{:ok, basis} = Replay.basis(receipt)

basis.admission
basis.plan_selection
basis.construction
basis.authorization   # %Replay.AuthorityRecord{}, not %AshA2A.Authority{}
basis.intended_effect
```

Insufficient or unbound identity refuses with a typed code rather than
fabricating a plausible basis. Binding checks go through
`AshA2A.Receipt.Binding.check/2`.

## 2. Refuse to re-actuate from the replayed authority

`basis.authorization` is an `AuthorityRecord` nested under
`AshA2A.Receipt.Replay`. It is deliberately **not** an `AshA2A.Authority`.
Stuffing it into a fresh `CommandBus` command is refused
(`:authority_required`), proven by
`test/ash_a2a_receipt_replay_counting_actuator_test.exs`.

```elixir
assert %Replay.AuthorityRecord{} = basis.authorization
refute match?(%AshA2A.Authority{}, basis.authorization)
```

This module never calls `CommandBus`, `Dispatcher`, or `Ash`. Repair for a
path that re-enters the actuator is the Chicago mutation
`replay_calls_actuator` in `lib/ash_a2a/chicago/mutation/catalog.ex`.

## 3. See Also

- `AshA2A.Receipt.Replay`
- [Test governed actions](test-governed-actions.md)
- [Verify receipts](verify-receipts.md) (Markdown standing-receipt hashing —
  a different surface)
- Chicago gate: `lib/ash_a2a/chicago/courts/offline_replay.ex`
