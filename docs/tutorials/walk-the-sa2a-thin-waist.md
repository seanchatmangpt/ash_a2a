# Walk the SA2A thin waist

Learn the six ash_a2a capabilities in order — discover → select → construct →
do → receipt → replay — without collapsing any adjacent pair into authority.

This is a learning trajectory. Executable procedures live in the how-tos linked
below; courts refuse the collapses this tutorial names.

## Contents

1. Discover (card honesty)
2. Select (choice ≠ authority)
3. Construct (artifact ≠ DO)
4. Do (CommandBus only)
5. Receipt (evidence ≠ success)
6. Replay (basis ≠ re-actuation)
7. See Also

## 1. Discover (card honesty)

An agent card advertises skills. It does not grant DO. Sign and verify cards
with [`sign-agent-cards`](../how-to/sign-agent-cards.md); repair drift with
[`repair-agent-card-drift`](../how-to/repair-agent-card-drift.md).

## 2. Select (choice ≠ authority)

`AshA2A.Semantic.Select` picks among admitted plan packages and returns
`:candidate` standing with `authority: :none`. Follow
[`select-among-plan-packages`](../how-to/select-among-plan-packages.md). Do not
hand a `Selection` to `CommandBus.run/4`.

## 3. Construct (artifact ≠ DO)

`AshA2A.Semantic.Construct` manufactures an artifact from admitted semantics.
Follow [`construct-from-admitted-semantics`](../how-to/construct-from-admitted-semantics.md).
Construction is not actuation.

## 4. Do (CommandBus only)

Consequence-bearing work crosses `AshA2A.CommandBus` with a real
`AshA2A.Authority`. Practice with
[`test-governed-actions`](../how-to/test-governed-actions.md). Intent, plans,
and constructed artifacts are not authority.

## 5. Receipt (evidence ≠ success)

A committed receipt records what was claimed and dispatched. Presence of a
receipt is not domain success. The same how-to covers receipt assertions in
tests.

## 6. Replay (basis ≠ re-actuation)

`AshA2A.Receipt.Replay.basis/1` reconstructs the semantic basis without
re-entering the actuator. Follow
[`replay-receipt-basis`](../how-to/replay-receipt-basis.md). A replayed
`AuthorityRecord` is deliberately not an `AshA2A.Authority`.

## 7. See Also

- Machine graph: `semantic/sa2a-diataxis.ttl`
- Closure query: `semantic/sa2a-diataxis-closure.rq` (empty = closed)
- HDDL method: `priv/sa2a_diataxis/methods.hddl` (`lawful-execution`)
- Getting started (first agent): [`getting-started`](getting-started.md)
