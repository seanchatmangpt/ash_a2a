# Test governed actions without mocks

Dispatch a `:change` or `:external_do` skill through the real
`AshA2A.CommandBus` in your own test suite, with a real in-process authority
broker and receipt store, no Postgres, and no mocks. The helper is
`AshA2A.Test.Governed` (`test/support/governed.ex`, compiled in `MIX_ENV=test`
of this repo; copy it into your app's `test/support` for your own suite).

## Contents

1. What it starts
2. Example
3. API
4. What it does not do
5. See Also

## 1. What it starts

- `AshA2A.ReceiptStore.Memory`, a `GenServer`, uniquely named per context.
- `AshA2A.Authority.Broker.InMemory`, a `GenServer` holding real issued and
  revoked grant state, uniquely named per context.

Both run under the test's ExUnit supervisor
(`ExUnit.Callbacks.start_supervised!/1`), so contexts are isolated from each
other and safe with `async: true`. Nothing mutates application environment.

## 2. Example

```elixir
defmodule MyApp.ItemGovernedTest do
  use ExUnit.Case, async: true
  alias AshA2A.Test.Governed

  @cap "MyApp.Item.create"

  test "create is refused without a grant, completes with one, refused after revoke" do
    gov = Governed.start!()

    assert {:error, %{code: :authority_required}} =
             Governed.run(gov, MyApp.Item, @cap, principal: "alice", input: %{label: "a"})

    gov = Governed.grant!(gov, "alice", @cap)

    assert {:ok, %{status: :completed, consequence: :change} = receipt} =
             Governed.run(gov, MyApp.Item, @cap, principal: "alice", input: %{label: "a"})

    assert {:ok, stored} = Governed.fetch_receipt(gov, receipt.command_id)
    assert stored.receipt_id == receipt.receipt_id

    gov = Governed.revoke!(gov, "alice", @cap)

    # distinct input: strict dedup would otherwise answer from the first receipt
    assert {:error, %{code: :authority_revoked}} =
             Governed.run(gov, MyApp.Item, @cap, principal: "alice", input: %{label: "b"})
  end
end
```

The same flow is exercised in `test/ash_a2a/docs_truth_test.exs`.

## 3. API

| Function | Purpose |
| --- | --- |
| `start!/1` | Start store and broker; returns the context. |
| `grant!/3` | Issue a real standing grant; returns the updated context (rebind it). |
| `revoke!/3` | Revoke it; the pre-DO revalidation then refuses `:authority_revoked`. |
| `run/4` | Build a command and call `CommandBus.run/4`; extra options pass through (`:actuation_dedup`, `:capability_release_closure`, ...). |
| `fetch_receipt/2` | Read the committed receipt from the context's store. |

`:observe` skills need no grant. Pass `command_id:` to test replay; the same
id and input yields `replayed?: true` with the same `receipt_id`.

## 4. What it does not do

- It does not touch the outbox directory setting: the default
  `System.tmp_dir!()` outbox is used, which is fine for tests.
- It does not exercise durable stores (`ReceiptStore.Ekv`, `Broker.Ekv`);
  qualify those with their own suites.
- Assert on returned and stored state and on effects your action bodies
  really performed (for example a counter process), not on call counts.

## 5. See Also

- [Test your ash_a2a app](test-your-ash_a2a-app.md)
- [Migrate legacy to strict](migrate-legacy-to-strict.md)
- [Configuration reference](../reference/configuration.md)
