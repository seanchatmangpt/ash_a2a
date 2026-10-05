# a2a_demo — runnable end-to-end ash_a2a demo

A minimal, runnable proof that the flagship ash_a2a surfaces work together in
one small app (~250 LOC of app code):

* one real Ash resource (`A2aDemo.Note`, ETS) with two skills:
  * `get_note` (`:read`, consequence `:observe`) — admitted with
    authentication alone;
  * `create_note` (generic `:action`, consequence `:change`,
    `lease_required? true`, Ash.Policy.Authorizer on the resource) — refused
    `:authority_required` unless the verified caller holds a standing grant
    for the resource-qualified capability id `"A2aDemo.Note.create_note"`;
* `use AshA2A.Agent` over that resource (card projected from the compiled
  capability index, never hand-written);
* ALL THREE A2A v1.0 transport bindings mounted:
  * `/jsonrpc` → `AshA2A.Transport.Plug` (JSON-RPC 2.0: `message/send`,
    `message/stream` SSE, `tasks/get`, `tasks/cancel`, …);
  * `/rest` → `AshA2A.Transport.HTTPJSON` (v1.0 REST: `POST /message:send`,
    `GET /tasks`, `GET /tasks/{id}`, `POST /tasks/{id}:cancel`);
  * gRPC → `AshA2A.Transport.GRPC.Server` on its own HTTP/2 endpoint
    (port `A2A_DEMO_GRPC_PORT`, default 4011), dispatched through
    `A2aDemo.GrpcHandler` — the same `AshA2A.Protocol.JSONRPC` dispatcher
    the HTTP mounts use;
* the agent card served at the ROOT `/.well-known/agent-card.json` (spec
  §8.2 discovery path) and at both transport mounts, with
  `supportedInterfaces` declaring all three bindings (JSONRPC / HTTP+JSON /
  GRPC) and the SA2A semantic profile advertised under `capabilities.extensions`
  on the JSON-RPC mount;
* optional signed card: set `A2A_DEMO_CARD_KEY` and the JSON-RPC card is
  signed at boot (HS256 detached JWS over the RFC 8785 canonical served
  document); the smoke run re-verifies the SERVED bytes with
  `AshA2A.Protocol.CardSigning.verify/2`.

## Run

```sh
cd examples/a2a_demo
MIX_BUILD_ROOT=_build-laneZ11 mix compile --warnings-as-errors
A2A_DEMO_CARD_KEY=demo-key mix run --no-halt
```

The listener binds port `4010` (override with `A2A_DEMO_PORT`); the gRPC endpoint binds `4011` (override with `A2A_DEMO_GRPC_PORT`). Boot log:

```
17:46:40.056 [warning] AshA2A legacy_compat profile: outbox_key_missing: receipt outbox is unkeyed; set :receipt_outbox_key or :receipt_binding_key
17:46:40.056 [warning] AshA2A legacy_compat profile: outbox_dir_not_durable: :receipt_outbox_dir nil is unset or under a tmp directory
17:46:40.056 [warning] AshA2A legacy_compat profile: receipt_store_in_memory: :receipt_store is AshA2A.ReceiptStore.Memory
17:46:40.056 [warning] AshA2A legacy_compat profile: capability_release_mode_legacy: :capability_release_mode must be :strict (capabilities unbound under :legacy)
17:46:40.056 [warning] AshA2A legacy_compat profile: kill_switch_class_missing: :kill_switch_class is nil; no class can be halted
17:46:40.056 [warning] AshA2A legacy_compat profile: claim_store_missing: no :claim_store configured; nothing durable backs claims
17:46:41.926 [info] Running A2aDemo.Router with Bandit 1.12.5 at 0.0.0.0:4010 (http)
```

(The `legacy_compat` security profile logs the strict preflight's findings as
warnings instead of refusing to boot — right for a demo whose receipt store
is deliberately in-memory. The profile is a compile-time constant of the
ash_a2a build, set in `config/config.exs`.)

## Credentials and authority

| token | identity | standing grant |
|---|---|---|
| `demo-token` | `%{id: "demo-user", tenant: "demo"}` | `"A2aDemo.Note.create_note"` (issued at boot) |
| `other-token` | `%{id: "other-user", tenant: "demo"}` | none — the fail-closed negative case |

Every route except the two card mounts runs the real `AshA2A.Protocol.Plug.Auth`
(bearer scheme, `A2aDemo.Auth.verify/3`) in front of the transport; a missing
or unknown token answers `401`.

## Falsifier: one command, every flow green

With the server running (`mix run --no-halt`, same env):

```sh
A2A_DEMO_CARD_KEY=demo-key mix run -e 'A2aDemo.Smoke.run()'
```

Or in ONE VM (app boots, smoke runs, exits):

```sh
A2A_DEMO_CARD_KEY=demo-key MIX_BUILD_ROOT=_build-laneZ11 mix run -e 'A2aDemo.Smoke.run()'
```

Actual output from this exact build:

```
RUN  card at /jsonrpc
RUN  card at /rest
RUN  observe read (message/send get_note)
RUN  input_required -> tasks/get -> tasks/cancel
RUN  grant-gated create (message/send create_note)
RUN  message/stream SSE
RUN  ungranted principal refused (authority gate)
RUN  unauthenticated refused (401)
RUN  REST message:send + tasks list/get
RUN  REST input_required -> cancel
PASS card at /jsonrpc
PASS card at /rest
PASS observe read (message/send get_note)
PASS input_required -> tasks/get -> tasks/cancel
PASS grant-gated create (message/send create_note)
PASS message/stream SSE
PASS ungranted principal refused (authority gate)
PASS unauthenticated refused (401)
PASS REST message:send + tasks list/get
PASS REST input_required -> cancel
ALL FLOWS GREEN (10 flows)
```

## curl flows (every transcript below is real captured output from this build)

With `$TOK = demo-token` and the server running.

### 0. Agent card (both mounts, unauthenticated)

```sh
curl -s http://localhost:4010/jsonrpc/.well-known/agent-card.json \
  | jq '{name, skills: [.skills[].id], extensions: [.capabilities.extensions[].uri], signatures: [.signatures[].header]}'
```

```json
{
  "name": "a2a-demo",
  "skills": ["A2aDemo.Note.create_note", "A2aDemo.Note.read"],
  "extensions": ["urn:sa2a:profile:v26.9.20"],
  "signatures": [{"alg": "HS256", "typ": "a2a-card"}]
}
```

```sh
curl -s http://localhost:4010/rest/.well-known/agent-card.json \
  | jq '{name, skills: [.skills[].id]}'
```

```json
{
  "name": "a2a-demo",
  "skills": ["A2aDemo.Note.create_note", "A2aDemo.Note.read"]
}
```

(The REST mount serves its card with `agent_card_opts`/extension injection
fixed empty inside the library — `AshA2A.Transport.HTTPJSON.card_json/3` —
so signatures and `capabilities.extensions` appear only on the JSON-RPC
mount's card.)

### 1. message/send — observe read

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"get_note"}}}}' \
  | jq '{state: .result.task.status.state, artifacts: .result.task.artifacts}'
```

```json
{
  "state": "TASK_STATE_COMPLETED",
  "artifacts": [
    {
      "artifactId": "art-cy4tbywqQ0kC",
      "parts": [{"data": {"results": []}}]
    }
  ]
}
```

### 2. message/send — missing argument parks the task INPUT_REQUIRED

`create_note` without its `text` argument:

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"message/send","params":{"message":{"messageId":"m2","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"create_note"}}}}' \
  | jq '{id: .result.task.id, state: .result.task.status.state, msg: .result.task.status.message.parts[0].text}'
```

```json
{
  "id": "tsk-eJDOhozcruWvbe366v_g8g",
  "state": "TASK_STATE_INPUT_REQUIRED",
  "msg": "\nInvalid Error\n\n* argument text is required\n  ..."
}
```

Keep the returned `id` for steps 3–4.

### 3. tasks/get

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tasks/get","params":{"id":"<TASK_ID>"}}' \
  | jq '{id: .result.id, state: .result.status.state}'
```

```json
{"id": "tsk-eJDOhozcruWvbe366v_g8g", "state": "TASK_STATE_INPUT_REQUIRED"}
```

### 4. tasks/cancel

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"tasks/cancel","params":{"id":"<TASK_ID>"}}' \
  | jq '{id: .result.id, state: .result.status.state}'
```

```json
{"id": "tsk-eJDOhozcruWvbe366v_g8g", "state": "TASK_STATE_CANCELED"}
```

### 5. message/send — grant-gated create (COMPLETED)

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":5,"method":"message/send","params":{"message":{"messageId":"m5","role":"ROLE_USER","parts":[{"data":{"text":"hello from curl"}}],"metadata":{"skill":"create_note"}}}}' \
  | jq '{state: .result.task.status.state, artifacts: .result.task.artifacts}'
```

```json
{
  "state": "TASK_STATE_COMPLETED",
  "artifacts": [
    {
      "artifactId": "art-e2gbgRbLvwjN",
      "parts": [{"data": {"id": "b524dbe3-baae-48c7-900b-e6e30c7a1734", "text": "hello from curl"}}]
    }
  ]
}
```

Then re-read through the observe skill and see the note:

```sh
# same command as step 1
```

```json
{"data": {"results": [{"id": "b524dbe3-baae-48c7-900b-e6e30c7a1734", "text": "hello from curl"}]}}
```

### 6. message/stream (SSE)

```sh
curl -sN -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":9,"method":"message/stream","params":{"message":{"messageId":"m9","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"get_note"}}}}'
```

```
data: {"id":9,"jsonrpc":"2.0","result":{"task":{"artifacts":[...],"id":"tsk-pcA7_qLTMCtmWzDrAq5-JQ","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2026-10-05T01:05:32.625573Z"}}}}

data: {"id":9,"jsonrpc":"2.0","result":{"artifactUpdate":{"artifact":{"artifactId":"art-66u25EJC1cHx","parts":[{"data":{"results":[...]}}]},"contextId":"ctx-jr5hz3AHc373k8NMVI4qpg","taskId":"tsk-pcA7_qLTMCtmWzDrAq5-JQ"}}}

data: {"id":9,"jsonrpc":"2.0","result":{"statusUpdate":{"contextId":"ctx-jr5hz3AHc373k8NMVI4qpg","status":{"state":"TASK_STATE_COMPLETED","timestamp":"2026-10-05T01:05:32.625573Z"},"taskId":"tsk-pcA7_qLTMCtmWzDrAq5-JQ"}}}
```

Three frames: the task snapshot, one `artifactUpdate` per artifact, and the
final `statusUpdate` (finality rides on the terminal state — the v1.0 wire
shape carries no `final` boolean).

### 7. Authority gate negative: valid credential, NO grant

```sh
curl -s -X POST http://localhost:4010/jsonrpc \
  -H "Authorization: Bearer other-token" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"message":{"messageId":"m7","role":"ROLE_USER","parts":[{"data":{"text":"should not land"}}],"metadata":{"skill":"create_note"}}}}' \
  | jq '{state: .result.task.status.state, msg: .result.task.status.message.parts[0].text}'
```

```json
{
  "state": "TASK_STATE_FAILED",
  "msg": "Error: %{code: :authority_required}"
}
```

The task fails and NOTHING is written — a step-1 re-read shows no
`should not land` note (the smoke asserts exactly this).

### 8. Unauthenticated → 401

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:4010/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":8,"method":"message/send","params":{"message":{"messageId":"m8","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"get_note"}}}}'
```

```
401
```

### 9. HTTP+JSON (REST) equivalents

```sh
# send
curl -s -X POST 'http://localhost:4010/rest/message:send' \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"message":{"messageId":"r1","role":"ROLE_USER","parts":[{"data":{}}],"metadata":{"skill":"get_note"}}}' \
  | jq '{id, state: .status.state}'
```

```json
{"id": "tsk-HWvEMWijufb0GvHxb4LVGg", "state": "TASK_STATE_COMPLETED"}
```

```sh
# list
curl -s http://localhost:4010/rest/tasks -H "Authorization: Bearer $TOK" | jq '{totalSize, ids: [.tasks[].id]}'
```

```json
{"totalSize": 7, "ids": ["tsk-HWvEMWijufb0GvHxb4LVGg", "tsk-pcA7_qLTMCtmWzDrAq5-JQ", ...]}
```

```sh
# get
curl -s "http://localhost:4010/rest/tasks/<TASK_ID>" -H "Authorization: Bearer $TOK" | jq '{id, state: .status.state}'
```

```json
{"id": "tsk-eJDOhozcruWvbe366v_g8g", "state": "TASK_STATE_CANCELED"}
```

```sh
# cancel (an INPUT_REQUIRED task from the REST send twin of step 2)
curl -s -X POST "http://localhost:4010/rest/tasks/<TASK_ID>:cancel" -H "Authorization: Bearer $TOK" \
  | jq '{id, state: .status.state}'
```

```json
{"id": "tsk-17Nhytw5ipQZKXMqXdwfgA", "state": "TASK_STATE_CANCELED"}
```

### 10. Extension / schema advertisement (one-liner)

The SA2A semantic profile is advertised on the JSON-RPC card by one option:

```elixir
extensions: [AshA2A.Semantic.Extension.capability_declaration()]
```

…in the `AshA2A.Transport.Plug.init/1` opts (`lib/a2a_demo/router.ex`), which
is what step 0's `capabilities.extensions` shows on the wire.

## A2A TCK mode (`A2A_DEMO_TCK=1`)

With the env set at BOTH compile and boot time the demo becomes a TCK SUT:

* the router drops its auth plug (the TCK sends no credentials);
* the agent opts into unauthenticated callers;
* a skill-less message defaults to the `get_note` observe read (a two-skill
  agent would otherwise refuse TCK traffic `{:ambiguous_skill, ...}`, capping
  the verdict at the SUT shape instead of the transport);
* gRPC callers are the anonymous principal -- the same key the agent derives
  for unauthenticated sends, so gRPC-created tasks are gRPC-visible.

Per-transport TCK verdicts (a2aproject/a2a-tck @ 263b9cf, python 3.12 venv,
2026-10-05): `--transport jsonrpc`: 5 failed / 74 passed / 186 skipped;
`--transport http_json`: 19 failed / 40 passed / 206 skipped; `--transport
grpc`: 11 failed / 44 passed / 210 skipped. Reports: /tmp/ge-tck/reports/.
Failure classes: artifact/message SUT shape (all transports), REST binding
gaps owned by the http_json lane, gRPC binding gaps owned by the grpc lane.

## Notes

* The demo mounts all three bindings: JSONRPC (`/jsonrpc`) and REST
  (`/rest`) on the Bandit listener, gRPC on the separate HTTP/2 endpoint.
* `A2aDemo.Smoke` (`lib/a2a_demo/smoke.ex`) is the falsifier — the same ten
  flows as this README, asserted on real wire state.
* The grant capability id is the resource-qualified id from the compiled
  capability index (`"A2aDemo.Note.create_note"`), the same id
  `AshA2A.Authority.Grant.authorize/3` is asked for at dispatch
  (SA2A-AUTH-017) — granting the bare skill name is silently insufficient.
* `AshA2A.Protocol.CardSigning.sign/3` signs the STRUCT projection of the
  card, while `AshA2A.Transport.Plug` serves a document with its own fixed
  `capabilities` override plus serve-time extension injection — a struct-signed
  card never verifies against the served bytes. `A2aDemo.CardSigning`
  works around it by building the JWS over the exact served document (same
  JCS canonicalization, same entry shape), which `CardSigning.verify/2` then
  verifies — proven by the smoke run.
* ash_a2a path-dep consumers additionally need two things this demo pins:
  `env: :dev` on the path dep (Mix compiles deps under its default `:prod`
  env, and `AshA2A.SecurityProfile` refuses demo profiles in prod), and a
  first build of ash_a2a into the demo's build dir before the demo app can
  load the dep's project config (`mix.exs` `docs/0` reads
  `Spark.Docs.search_data_for(AshA2A)` before ash_a2a is compiled).
