# Construct from admitted semantics

Manufacture an artifact from admitted ontology/projection inputs without
implying DO. This is RFC-SA2A-001 S26 (`AshA2A.Semantic.Construct`).

## Contents

1. Call `Construct.construct/4`
2. Keep construction receipts distinct from CommandBus receipts
3. See Also

## 1. Call `Construct.construct/4`

```elixir
alias AshA2A.Semantic.Construct

{:ok, construction} =
  Construct.construct(
    admitted_inputs,
    manufacturer,
    target_profile,
    opts
  )

construction.standing
#=> :candidate

construction.authority
#=> :none

construction.artifact_digest
#=> "sha256:..."
```

`standing` and `authority` are unconditional markers on the result struct.
Construction never calls `CommandBus`, `Dispatcher`, or `Ash`.

## 2. Keep construction receipts distinct from CommandBus receipts

`construction.construction_receipt` is **not** an `AshA2A.Receipt`. The
consequence receipt is what `CommandBus` commits after a real DO. Collapsing
the two would make "I generated a file" look like "I committed a change".

```elixir
assert construction.construction_receipt.__struct__ != AshA2A.Receipt
```

Courts: `test/ash_a2a/semantic_construct_test.exs` and the plan-package
Chicago court (`construct_implies_do` failure class).

## 3. See Also

- `AshA2A.Semantic.Construct` / `AshA2A.Semantic.Construction`
- [Select among plan packages](select-among-plan-packages.md)
- [Test governed actions](test-governed-actions.md) (real DO receipts)
- Machine method: `priv/sa2a_diataxis/methods.hddl` (`lawful-execution`)
