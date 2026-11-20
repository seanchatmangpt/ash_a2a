# Select among plan packages

Choose one admitted plan package from a candidate set without granting DO
authority. This is RFC-SA2A-001 S25 (`AshA2A.Semantic.Select`).

## Contents

1. Call `Select.select/3`
2. Assert candidate standing
3. See Also

## 1. Call `Select.select/3`

```elixir
alias AshA2A.Semantic.{PlanPackage, Select}

# candidates must already be verifiable PlanPackages
scorer = fn %PlanPackage{max_depth: depth} -> depth end

{:ok, selection} =
  Select.select(candidates, scorer, selector_identity: "planner-a")

selection.chosen_digest
#=> "sha256:..."

selection.standing
#=> :candidate

selection.authority
#=> :none
```

The scorer returns a **cost**; the lowest cost wins. Ties break on
`plan_digest` ascending so the choice is order-independent.

Refusals are typed: empty candidates, an unverifiable package, a profile
violation, or a non-numeric scorer return.

## 2. Assert candidate standing

A selection is evidence of a choice, not authority to actuate. Do not pass
`selection` into `CommandBus.run/4`. The compiled module's import table
contains no `CommandBus` / `Receipt` / `Ash` edge; that is the court in
`test/ash_a2a/semantic_select_test.exs`.

```elixir
assert selection.standing == :candidate
assert selection.authority == :none
refute function_exported?(Select, :execute, 1)
```

## 3. See Also

- `AshA2A.Semantic.Select` / `AshA2A.Semantic.Selection`
- [Construct from admitted semantics](construct-from-admitted-semantics.md)
- [Enable semantic requests](enable-semantic-requests.md)
- Machine method: `priv/sa2a_diataxis/methods.hddl` (`lawful-execution`)
