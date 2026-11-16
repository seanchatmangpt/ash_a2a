# Event journal contract

Status: compiled and run; see Tests below.

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
- Artifact writes bump the task generation but are not journaled as `artifactUpdate` events; the closing `statusUpdate` of that write carries the generation.
- A client further behind than the retained tail (see Retention) gets only that tail, with no gap marker.

## Writer

With `config :ash_a2a, :event_journal, {module, ref}` set, `AshA2A.Protocol.Agent.State.put_task_checked/2`
(the one function every task write of `AshA2A.Protocol.Agent` and `AshA2A.Agent` goes through) calls
`AshA2A.Protocol.EventJournal.record_task/3` after the write is accepted. It appends, for each timeline
entry newer than the previously stored generation, a `StreamResponse` map (`messageUpdate` or
`statusUpdate`) at that entry's generation, then a closing `statusUpdate` at the task's current
generation when the timeline has none. Events are journaled whether or not a subscriber is attached.

An append that returns an error, raises, throws or exits does not fail the task write or crash the
agent: it is logged and emitted as `[:ash_a2a, :event_journal, :append_failed]`
(metadata `task_id`, `generation`, `operation`).

## Retention

When a task reaches a terminal state its journal is trimmed to the newest
`config :ash_a2a, :event_journal_keep_last` events (default 256). Non-terminal tasks are not trimmed.

## Tests

- `test/ash_a2a/event_journal_ets_test.exs`: ordering, generation filter, trim, concurrency, unavailable table.
- `test/ash_a2a/event_journal_ekv_test.exs`: single-node round trip and concurrency; a two-peer EKV cluster where events appended on node A replay on node B (tags `serial`, `serial_solo`).
- `test/ash_a2a/event_journal_writer_test.exs`: the writer end to end over the ETS journal: every task write journaled with its generation, agent killed and restarted then `tasks/resubscribe` replaying the missed events in order over a `Plug.Test` SSE conn, terminal trim, and a refusing, raising or exiting journal not failing the task write.
- `test/ash_a2a/event_journal_crossnode_test.exs`: an agent on peer node A runs a task; a second agent on peer node B replays its events through the EKV journal (tags `serial`, `serial_solo`; run with `mix test.serial.solo`).
