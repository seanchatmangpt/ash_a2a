# How to run the simulation server

The simulation server boots every transport ash_a2a ships against one agent
with real Ash mutations, on real listeners. Use it to drive the library by
hand, or run its prover to check that every served method, route and RPC
answers correctly over the wire.

Nothing in it is mocked: the HTTP mounts run on Bandit, the gRPC endpoint is
the library's own, push notifications are delivered to a real webhook
receiver, and the notes live in the Ash ETS data layer.

## Prove the whole surface

```console
mix ash_a2a.sim --prove
```

The task boots the server on free ports, runs every probe, and prints one row
per probe:

```text
SURFACE                              PROBE                                     STATUS  DETAIL
jsonrpc_method:message/send          blocking send completes ... (/a2a)        pass    task tsk-... completed with 1 artifact(s)
skill:AshA2A.Sim.Note.create         create over JSON-RPC writes the row       pass    row 5c1e... read back through Ash with the sent title and body
skill:AshA2A.Sim.Note.create         create without authority is refused ...   pass    refused authority_required; row count stays 17
...
205 probes over 83 surface items: 204 pass, 0 fail, 1 skip
```

The exit status is `1` when any probe fails, or when a served surface item
has no probe. Add `--json` to get the same matrix as a JSON object with
`summary`, `uncovered` and `results`.

A `skip` row is a known library defect the prover observed. Its detail says
what the defect is and where it lives.

The same run is a test:

```console
mix test test/ash_a2a/sim/sim_mirror_test.exs
```

## Check A2A v1.1 parity

```console
mix ash_a2a.sim --parity
```

This compares the server's wire output with an independent reference built
from the upstream v1.1 proto. It needs a Python virtual environment; see
[How to check A2A v1.1 parity](check-a2a-v1-1-parity.md). The same comparison
appears as the `parity:` rows of `--prove`, which report `skip` when the
environment is missing.

## Serve it and call it yourself

```console
mix ash_a2a.sim
```

The task prints the URL of each mount and the bearer tokens, then serves
until you stop the VM. Pass `--http-port`, `--grpc-port` and `--push-port` to
pin the ports; each defaults to a free port.

| Mount | Served by |
| --- | --- |
| `GET /.well-known/agent-card.json` | the agent card, no credentials needed |
| `/jsonrpc` | `AshA2A.Transport.Plug` (JSON-RPC 2.0, owner-scoped tasks) |
| `/a2a` | `AshA2A.A2ATransport.Plug` (JSON-RPC 2.0 with push configs, resubscribe and the extended card) |
| `/rest` | `AshA2A.Transport.HTTPJSON` (HTTP+JSON, including `message:live` and the schema endpoints) |
| gRPC port | `AshA2A.Transport.GRPC.Server` (`lf.a2a.v1.A2AService`) |
| push port | `AshA2A.Sim.PushReceiver`, which records every webhook it receives |

Every mount except the card requires a bearer token:

| Token | What it can do |
| --- | --- |
| `sim-writer-token` | Everything. It holds the standing grants for the mutating skills. |
| `sim-reader-token` | Read-only skills. A mutating skill is refused by the authority gate. |
| `sim-unscoped-token` | Nothing. It lacks the `a2a:invoke` scope and is refused `403`. |

These tokens are public test fixtures.

Create a note over JSON-RPC (replace the port with the one the task printed):

```console
curl -s http://127.0.0.1:PORT/jsonrpc \
  -H 'authorization: Bearer sim-writer-token' \
  -H 'a2a-version: 1.1' \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{
        "messageId":"m-1","role":"ROLE_USER",
        "parts":[{"data":{"title":"hello","body":"first note"}}],
        "metadata":{"skill":"create_note"}}}}'
```

The same call with `sim-reader-token` answers a task in `TASK_STATE_FAILED`
whose status names `authority_required`, and no row is written.

## The skills

`AshA2A.Sim.Note` exposes one skill for every Ash action type and every
consequence class. Name the skill in the message's `metadata.skill`, and send
its arguments as a data part.

| Skill | Action | Consequence | What it shows |
| --- | --- | --- | --- |
| `list_notes` | read | observe | Add `"stream": true` to the data part to get the rows as streamed artifact chunks. |
| `create_note` | create | change | Send it without `title` to park the task at input-required, then send `title` with the same `taskId`. |
| `update_note` | update | change | Takes the note `id` and the fields to change. An unknown `id` fails the task. |
| `delete_note` | destroy | change | Takes the note `id`. |
| `count_notes` | generic | observe | Counts the rows. |
| `slow_count` | generic | observe | Sleeps `delay_ms` first, so you can cancel it or resubscribe to it while it runs. |
| `step_up` | generic | observe | Parks at auth-required until you send `otp` with the same `taskId`. |
| `publish_note` | generic | external_do | Records a publication outside the data layer (`AshA2A.Sim.Note.publications/0`). |
| `unclassified_note` | generic | unknown | Always rejected: nobody classified its consequence. |

## Drive the email gateway

The server also mounts the email gateway of
[Operate by email](operate-by-email.md) (`AshA2A.Email.Plug`,
`POST /v1/email:ingest`), with everything it needs. It authenticates its own
webhook, so these two mounts take no bearer token.

| Mount | Webhook authentication |
| --- | --- |
| `POST /email/v1/email:ingest` | an SES-shaped envelope; the provider check is `AshA2A.Email.Dkim.verifier/1` over the raw message in `content`, plus the SNS topic ARN |
| `POST /email-workspace/v1/email:ingest` | a Bearer webhook secret the server generates per run |

Behind both: a fresh RSA-2048 DKIM key per run (the resolver answers it for
`sim.example`, selector `sim`), a durable replay ledger
(`AshA2A.Email.TokenLedgerStore` on an EKV instance in a temporary directory,
removed on stop), a sender allowlist, 64 KiB and 2000-character caps and a
60-requests-per-minute limit per sender. A brief action runs the governed
kernel entry against `AshA2A.Sim.Note` under the sender's standing grant:
`approver@sim.example` and `other@sim.example` hold the `create_note` and
`publish_note` grants, `ungranted@sim.example` holds none.

`AshA2A.Sim.Email` issues briefs and signs real mail, so you can post by hand
from `mix run` or let the prover do it:

```elixir
brief = AshA2A.Sim.Email.issue_brief()
reply = AshA2A.Sim.Email.build_reply(brief, text: "Approve 1.")
AshA2A.Sim.Email.post(info, reply.envelope).status
#=> 200
```

The prover has one probe per route and one per outcome
(`AshA2A.Sim.Email.outcomes/0`), each a real HTTP POST followed by a read of
the Ash rows:

| Outcome | Wire answer | Row changes |
| --- | --- | --- |
| honest approved reply | 200 `dispatched` | the note exists |
| same message id again | 200 with `replayed: true` | no |
| same token, new message id | 409 `already_consumed` | no |
| one byte flipped after signing | 401 `webhook_unauthorized` | no |
| wrong or missing webhook secret, another SNS topic | 401 | no |
| signed with a key the resolver does not publish | 401 | no |
| `l=` body-length tag | 401 | no |
| From outside the signing domain | 401 | no |
| envelope text, sender or ids that differ from the signed message | 401 | no |
| sender off the allowlist | 401 `sender_not_allowlisted` | no |
| brief bound to another approver | 403 `approver_mismatch` | no |
| reply token missing or forged | 403 `invalid_reply_token` | no |
| reply to an unknown message id | 404 `brief_not_found` | no |
| body over 64 KiB | 413 `payload_too_large` | no |
| body nested over 8 levels | 413 `payload_too_complex` | no |
| graph changed since the brief | 409 `stale_graph_digest`, a reconfirm brief is mailed and can be approved | no |
| authenticated sender with no standing grant | 200 `refused` | no |
| 61 requests in a minute from one sender | 429 `rate_limited` | no |

`AshA2A.Sim.Email.drift/1` changes the simulated graph under a brief, and
`AshA2A.Sim.Email.advance_clock/1` empties the rate-limit window without
waiting. To read what the gateway mailed, use `AshA2A.Sim.Email.deliveries/0`
(or the `sim_email_deliveries` MCP tool).

The test is `mix test test/ash_a2a/sim/sim_email_test.exs`.

## Start it from code

```elixir
{:ok, _pid} = AshA2A.Sim.Server.start_link()
info = AshA2A.Sim.Server.info()

results = AshA2A.Sim.Prover.run(info)
AshA2A.Sim.Prover.summary(results)
#=> %{pass: 204, fail: 0, skip: 1}

Ash.read!(AshA2A.Sim.Note, authorize?: false)
```

`AshA2A.Sim.Server.child_spec/1` lets you put it under a supervisor. Only one
simulation server can run in a VM, because the agent is registered under its
module name and the gRPC server reads one application environment.

The server and the prover are compiled only when Bandit is available. Bandit
is an optional dependency of ash_a2a (`optional: true` in `mix.exs`). In this
repository `mix ash_a2a.sim` defaults to the `test` Mix environment and also
runs with `MIX_ENV=dev`. To use the simulation server from another project,
add `{:bandit, "~> 1.5"}` and a SAT solver for the Ash policies of the
simulation resource (`{:simple_sat, "~> 0.1"}`, also optional here) to that
project's dependencies. Without Bandit the library still compiles, none of
the `AshA2A.Sim.*` modules exist, and the task stops with a message naming
the missing dependency.

## How the mirror stays honest

`AshA2A.Sim.Surface` derives the inventory from the library, not from a
hand-kept list:

- JSON-RPC methods and aliases come from the dispatcher's own clauses and
  alias tables.
- gRPC RPC names come from the A2A proto file.
- HTTP+JSON routes come from the dispatch clauses of
  `AshA2A.Transport.HTTPJSON`.
- Skills come from `AshA2A.Info.capability_index/1`, consequence classes from
  the `a2a` DSL, and task states from the generated proto enum.

The test asserts that every item has at least one probe. If you add a method,
a route or an RPC to the library, that test fails until you add a probe for
it in `AshA2A.Sim.Prover`.
