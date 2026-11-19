# How to operate the event journal

Status: the writer, trim and replay paths are covered by
`test/ash_a2a/event_journal_ets_test.exs`, `test/ash_a2a/event_journal_writer_test.exs`
and `test/ash_a2a/event_journal_ekv_test.exs`. The two-node replay test
(`test/ash_a2a/event_journal_crossnode_test.exs`) is tagged `serial_solo`. The
callback contract is in the [event journal reference](../reference/event-journal.md).

The event journal records one event per task mutation so that
`tasks/resubscribe` (JSON-RPC) and `SubscribeToTask` with `lastSeenGeneration`
can replay what a client missed, even after the agent process restarted or the
subscriber reconnected to another node. Without a journal a stream replays only
from the node-local event log or the task snapshot.

## Wire it

1. Start a journal in your supervision tree. In memory (lost on node restart):

   ```elixir
   children = [
     {AshA2A.TaskStore.EventJournalEts, name: MyApp.EventJournal}
   ]
   ```

   Or on disk and replicated, sharing an EKV instance with the task store (event
   keys use the `a2a_event/` prefix):

   ```elixir
   children = [
     AshA2A.TaskStore.Ekv.child_spec(name: MyApp.Tasks, data_dir: "/var/lib/my_app/tasks")
   ]
   ```

2. Tell the library which one to use. The value is `{module, ref}`:

   ```elixir
   # config/runtime.exs
   config :ash_a2a, :event_journal, {AshA2A.TaskStore.EventJournalEts, MyApp.EventJournal}
   # or
   config :ash_a2a, :event_journal, {AshA2A.TaskStore.EventJournalEkv, MyApp.Tasks}
   ```

   Unset means no journal. `AshA2A.Protocol.EventJournal.configured/0` returns what
   is set.

From then on every task write of `AshA2A.Protocol.Agent` and `AshA2A.Agent` is
journaled, whether or not a subscriber is attached.

## Config keys

| Key | Default | Meaning |
| --- | --- | --- |
| `:event_journal` | unset (no journal) | `{module, ref}` of the journal that the writer appends to and `tasks/resubscribe` replays from. |
| `:event_journal_keep_last` | 256 events | How many events a task keeps once it is terminal. Non-terminal tasks are never trimmed. |
| `:resubscribe_orphan_grace_ms` | 500 ms | How long a resubscribe waits for a producer of a non-terminal task before it closes with a `StreamError` (`PRODUCER_UNAVAILABLE`). |

These rows are also in the [configuration reference](../reference/configuration.md).

## Check that it replays

The simulation server (`mix ash_a2a.sim --http-port 4190`) configures an ETS journal.
Start a slow task without waiting for it, then subscribe from generation 1:

```console
$ curl -s http://127.0.0.1:4190/rest/message:send \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' \
    -H 'content-type: application/json' \
    -d '{"message":{"messageId":"m-j2","role":"ROLE_USER","parts":[{"data":{"delay_ms":2500}}],"metadata":{"skill":"slow_count"}},"configuration":{"returnImmediately":true}}' \
    | jq -r .task.id
tsk-HVOgb2vc3XASQF1tMNAegQ
$ curl -s -N "http://127.0.0.1:4190/rest/tasks/tsk-HVOgb2vc3XASQF1tMNAegQ:subscribe?lastSeenGeneration=1" \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' | cut -c1-120
data: {"messageUpdate":{"contextId":"ctx-6IKIsrYG_mNzwhCxm8X6XQ","generation":"2","message":{"messageId":
data: {"artifactUpdate":{"artifact":{"artifactId":"art-gOIVwsZkoioi","endGeneration":"3","parts":[{"data":
data: {"statusUpdate":{"contextId":"ctx-6IKIsrYG_mNzwhCxm8X6XQ","generation":"4","status":{"state":"TASK_STATE_COMPLETED",
```

There is no snapshot frame because the client says it is current as of generation 1;
every frame carries a generation greater than that. A terminal task refuses a new
subscription (`UNSUPPORTED_OPERATION`), so subscribe while the task is running.

## Operating notes

- A failed append is logged and emitted as `[:ash_a2a, :event_journal, :append_failed]`
  (metadata `task_id`, `generation`, `operation`). It does not fail the task write. Alert
  on that event: a journal that is down turns replay into snapshot-only.
- Replay is by generation. A client that saw part of a generation gets whole later
  generations, not the rest of the one it was in.
- A client further behind than the retained tail gets only the tail, with no gap marker.
  Raise `:event_journal_keep_last` if clients can be offline long.
- The ETS journal is lost on node restart. Use the EKV journal for anything that must
  survive one, and set a persistent `:data_dir`.
- EKV replay reads the local replica and orders concurrent appends by wall clock. An event
  appended on another node a moment ago may not be visible yet.
- The journal is storage, not authority: a replay passes the same owner check as
  `tasks/get`. Never put credentials (`"a2a.auth"`) in events.
- To store events somewhere else, implement the three callbacks `append/4`,
  `replay_after/3` and `trim/3` of `AshA2A.Protocol.EventJournal` and configure
  `{YourModule, ref}`.
