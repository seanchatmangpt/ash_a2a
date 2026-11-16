# Event journal contract

Status: **UNVERIFIED**. Written without an Elixir toolchain; nothing here has been compiled or run.

`AshA2A.Protocol.EventJournal` records per-task events so a stream that resubscribes on a fresh
agent or a second node can replay what it missed, instead of receiving only the `TaskStore`
snapshot. Lane W2-02 builds SSE reattach on these callbacks.

A journal is `{module, ref}` (like `:task_store`). `ref` is passed as the first argument of
every callback; the callback names are fixed.

| Callback | Contract |
|---|---|
| `append(ref, task_id, generation, event)` | `:ok` only after the event was read back; `{:error, :not_stored}` if the write was silently dropped; `{:error, :journal_unavailable \| reason}` otherwise. |
| `replay_after(ref, task_id, generation)` | `{:ok, events}`: every event with generation **strictly greater** than `generation`, ordered by generation then append order. Raw events as appended. `-1` replays everything. |
| `trim(ref, task_id, keep_last)` | `:ok`; keeps the newest `keep_last` events of that task (across generations); other tasks untouched. |

`AshA2A.Protocol.EventJournal.append/4`, `replay_after/3`, `trim/3` dispatch on a `{module, ref}` tuple.

## Implementations

| Module | Storage | Order | Durability |
|---|---|---|---|
| `AshA2A.TaskStore.EventJournalEts` (default) | named ordered ETS table, started with `{EventJournalEts, name: ref}` | exact per task and generation (atomic counter) | lost on node restart |
| `AshA2A.TaskStore.EventJournalEkv` | `EKV` instance (can share `AshA2A.TaskStore.Ekv`'s), prefix `a2a_event/` | wall-clock microseconds, then node, then local counter | on disk, replicated across EKV nodes |

## Limits (honest)

- Replay by generation only: a reattaching client that saw part of a generation cannot resume mid-generation; it gets the whole next generations. A finer cursor is not part of this contract.
- EKV order across nodes is wall-clock order; clock skew can reorder concurrent appends to the same generation.
- EKV replay reads the local replica (eventual); an event appended on another node moments ago may not be visible yet.
- The journal is storage, not authority. A replaying caller must pass the same owner check as `tasks/get`. Events are stored as given: callers must not journal credentials (`"a2a.auth"`).
- Nothing yet calls `append` from the agent/transport; wiring is W2-02's work. Retention is the caller's responsibility via `trim`.

## Tests (all UNVERIFIED, not run)

- `test/ash_a2a/event_journal_ets_test.exs`: ordering, generation filter, trim, concurrency, unavailable table.
- `test/ash_a2a/event_journal_ekv_test.exs`: single-node round trip and concurrency; a two-peer EKV cluster where events appended on node A replay on node B (tags `serial`, `serial_solo`).
