# Prove your agent with the simulation server

In this tutorial you run the A2A v1.1 simulation server, call it with `curl` on
two bindings and with a small gRPC client on the third, run the prover and the
byte-for-byte parity check, drive the server from an MCP client, and then point
the same tools at an agent of your own.

Every command and output below was run on 2026-11-17 in this repository
(Elixir 1.20.4 / OTP 29.1.1, `MIX_ENV=test`). Ids, timestamps and ports differ on
your machine. Counts (probes, rows) grow as probes are added; yours may be higher.

You need the repository checked out and compiled, `curl` and `jq`. The parity
step also needs Python 3.10+ and PyPI access, once, to build the reference
(`scripts/a2a_v1_1_parity/setup.sh`).

## 1. Run the simulation server

```console
$ mix ash_a2a.sim --http-port 4190 --grpc-port 50190 --push-port 4191
ash_a2a simulation server

  agent card     http://127.0.0.1:4190/.well-known/agent-card.json
  JSON-RPC       http://127.0.0.1:4190/jsonrpc   (AshA2A.Transport.Plug)
  JSON-RPC       http://127.0.0.1:4190/a2a   (AshA2A.A2ATransport.Plug: push configs, extended card)
  HTTP+JSON      http://127.0.0.1:4190/rest   (AshA2A.Transport.HTTPJSON)
  gRPC           127.0.0.1:50190   (lf.a2a.v1.A2AService)
  push receiver  http://127.0.0.1:4191/hook

Bearer tokens

  writer    sim-writer-token   (holds the grants for the mutating skills)
  reader    sim-reader-token   (no grants)
  unscoped  sim-unscoped-token   (lacks the a2a:invoke scope)

Serving until stopped.
```

Leave it running and use a second terminal. Without the port flags each port is free
and the task prints it. The server is a real A2A v1.1 agent over an ETS note store:
every transport the library ships, with real Ash mutations.

## 2. Read the agent card

```console
$ curl -s http://127.0.0.1:4190/.well-known/agent-card.json \
    | jq -c '{name, supportedInterfaces: .supportedInterfaces[0], signatures: (.signatures|length)}'
{"name":"ash-a2a-sim","supportedInterfaces":{"protocolBinding":"JSONRPC","protocolVersion":"1.1","url":"http://127.0.0.1:4190/a2a"},"signatures":1}
```

The card lists the four mounts (two JSON-RPC, one HTTP+JSON, one gRPC) and carries one
signature: the server signs every card it serves.

## 3. Call each binding

The `create_note` skill writes a row, so it needs a standing grant: the writer token
has it. Name the skill in `metadata.skill` and send its arguments as a data part.

**JSON-RPC**

```console
$ curl -s http://127.0.0.1:4190/jsonrpc \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"messageId":"m-1","role":"ROLE_USER","parts":[{"data":{"title":"hello","body":"first note"}}],"metadata":{"skill":"create_note"}}}}' \
    | jq -c '.result.task | {id, state: .status.state, generation, artifact: .artifacts[0].parts[0].data}'
{"id":"tsk-NumrpgST1amVzcW6eogyGQ","state":"TASK_STATE_COMPLETED","generation":"5","artifact":{"id":"e4fdd33f-aef5-4e40-9275-9fbe0efc3fdb","title":"hello","body":"first note"}}
```

`generation` is a string: int64 members are decimal strings on the v1.1 wire.

**HTTP+JSON**

```console
$ curl -s http://127.0.0.1:4190/rest/message:send \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' \
    -H 'content-type: application/json' \
    -d '{"message":{"messageId":"m-2","role":"ROLE_USER","parts":[{"data":{"title":"second","body":"over rest"}}],"metadata":{"skill":"create_note"}}}' \
    | jq -c '.task | {id, state: .status.state, generation}'
{"id":"tsk-ri-V26S49JPl6FY-5G_Bmw","state":"TASK_STATE_COMPLETED","generation":"5"}
```

Read the task back:

```console
$ curl -s http://127.0.0.1:4190/rest/tasks/tsk-O_sYI2PfXPUiqW8nkLfMCA \
    -H 'authorization: Bearer sim-writer-token' -H 'a2a-version: 1.1' \
    | jq -c '{id, state: .status.state, generation}'
{"id":"tsk-O_sYI2PfXPUiqW8nkLfMCA","state":"TASK_STATE_COMPLETED","generation":"5"}
```

**gRPC.** No `grpcurl` is needed: the parity setup generates Python stubs from the
upstream proto, and they work as a client. Run from the repository root:

```console
$ scripts/a2a_v1_1_parity/setup.sh        # once; creates /tmp/a2a_v1_1_parity/venv
$ /tmp/a2a_v1_1_parity/venv/bin/python -I - <<'EOF'
import sys
sys.path.insert(0, "scripts/a2a_v1_1_parity")   # the stubs setup.sh generated
import grpc
from google.protobuf import json_format, struct_pb2
from reference import pb, pb_grpc

stub = pb_grpc.A2AServiceStub(grpc.insecure_channel("127.0.0.1:50190"))
data = struct_pb2.Struct()
data.update({"title": "third", "body": "over gRPC"})
meta = struct_pb2.Struct()
meta.update({"skill": "create_note"})
message = pb.Message(message_id="m-4", role=pb.ROLE_USER, metadata=meta,
                     parts=[pb.Part(data=struct_pb2.Value(struct_value=data))])
reply = stub.SendMessage(
    pb.SendMessageRequest(message=message),
    metadata=(("authorization", "Bearer sim-writer-token"), ("a2a-version", "1.1")))
print(pb.TaskState.Name(reply.task.status.state), "generation", reply.task.generation)
print(json_format.MessageToJson(reply.task.artifacts[0].parts[0], indent=None))
EOF
TASK_STATE_COMPLETED generation 5
{"data": {"id": "8b16f025-62a7-4ecc-91ad-bf2e9d028a7c", "title": "third", "body": "over gRPC"}}
```

**A refusal.** The reader token holds no grant, so the same call is refused by the
authority gate, over any binding, and no row is written:

```console
$ curl -s http://127.0.0.1:4190/jsonrpc \
    -H 'authorization: Bearer sim-reader-token' -H 'a2a-version: 1.1' \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":2,"method":"message/send","params":{"message":{"messageId":"m-9","role":"ROLE_USER","parts":[{"data":{"title":"nope"}}],"metadata":{"skill":"create_note"}}}}' \
    | jq -c '.result.task.status | {state, text: .message.parts[0].text}'
{"state":"TASK_STATE_REJECTED","text":"Rejected: %{code: :authority_required}"}
```

The task ends `TASK_STATE_REJECTED`, not `FAILED`: a refusal before dispatch is a
rejection. The unscoped token never reaches dispatch: `curl -o /dev/null -w '%{http_code}'`
against `/rest/message:send` with `sim-unscoped-token` printed `403`.

Stop the server (Ctrl-C twice) before the next step if you like; the next two commands
boot their own on free ports.

## 4. Prove every served method, route and RPC

```console
$ mix ash_a2a.sim --prove
SURFACE                              PROBE                                     STATUS  DETAIL
jsonrpc_method:agent/getAuthenticatedExtendedCard   an authenticated caller gets the extended card (/a2a)   pass   12 skills, 1 more than the public card
...
243 probes over 86 surface items: 243 pass, 0 fail, 0 skip
```

(Rows elided; the table is about 240 lines. Column widths shortened here.) The
inventory is derived from the library, so a method, route or RPC with no probe fails the
run: the exit status is `1` on a failed probe or an uncovered item (it was `0`).
`--json` prints the matrix as JSON. The same run is a test:
`mix test test/ash_a2a/sim/sim_mirror_test.exs`.

## 5. Compare the wire with the upstream reference

```console
$ mix ash_a2a.sim --parity --strict
BINDING             pass  fail known  skip
agent-card            16     0     0     0
grpc                 295     0     0     0
http+json            288     0     0     0
jsonrpc              292     0     0     0
jsonrpc:/jsonrpc     173     0     0     0
v1.0                 207     0     0     0
cross-binding          7     0     0     0
coverage               5     0     0     0
total               1283     0     0     0
```

Each row compares one response with a reference encoder built from the upstream proto at
tag `v1.1.0-rc` and the official protobuf runtime, byte for byte; none of the reference
shares code with ash_a2a. The exit status was `0`. Without the virtual environment the
task exits `2` and says so. See [How to check A2A v1.1 parity](../how-to/check-a2a-v1-1-parity.md).

## 6. Drive it from an MCP client

`.mcp.json` in the repository root registers `bin/a2a-sim-mcp`. In Claude Code, open
the repository and approve the `a2a-sim` server; its tools appear as
`mcp__a2a-sim__*`. The client below made these two calls in the session that wrote this
page.

`a2a_send_message` with `{"binding":"grpc","skill":"create_note","data":{"title":"from an MCP client","body":"tutorial"}}` answered
`"final_state":"TASK_STATE_COMPLETED"`, `"status_name":"OK"` with the created row in `data`.
Then `sim_read_rows` with `{"title":"from an MCP client"}`, which reads the Ash data layer
without any A2A call, answered:

```json
{"count":1,"publications":[],"rows":[{"body":"tutorial","id":"b2f6f408-47c9-4a15-bf8a-414e450fec8a","title":"from an MCP client", "...":"..."}],"total":1}
```

Without an MCP client, `scripts/mcp_drive.py` is one (standard library only). Each
invocation starts its own server:

```console
$ python3 scripts/mcp_drive.py --call a2a_send_message '{"binding":"grpc","skill":"create_note","data":{"title":"from mcp"}}'
...
  "final_state": "TASK_STATE_COMPLETED",
...
$ python3 scripts/mcp_drive.py --list | wc -l      # 70 tools plus a header line
71
```

`python3 scripts/mcp_drive.py` with no arguments drives the whole surface through MCP
and exits non-zero on any failure. Note: at the time this tutorial was written other work
on the simulation surface was in flight (email and authority surface items without an MCP
mapping yet), and that run exited `1` with 47 uncovered items; the last clean run is
recorded in the CHANGELOG (93 of 93 items). Rerun it for the current state. The tool
catalog and every argument are in
[How to control the simulation over MCP](../how-to/control-the-sim-over-mcp.md).

## 7. Point it at your own agent

The prover and the parity check are written for the simulation agent's skills, so they
test the library's transports, not your agent. For your own agent, use the same
requests and the checks that read your wiring:

1. Mount your agent as in the [Getting Started tutorial](getting-started.md) and run
   the `curl` calls of step 3 against its URL, with your skill names and your
   credentials.
2. Check the wiring of your domains without starting anything:

   ```console
   $ mix ash_a2a.doctor
   [error] authenticated_caller_disabled: Application config :require_authenticated_caller is false; unauthenticated callers are admitted.
   [warn] config_receipt_binding_key_unset: :receipt_binding_key is unset: receipt binding is refused (:receipt_binding_key_unavailable) until it is set.
   ...
   ** (Mix) ash_a2a.doctor found problems
   ```

   That is this repository's own test configuration (the exit status is non-zero on any
   `error`). See [Run the doctor](../how-to/run-doctor.md).
3. Check that your card claims only what you mounted, using `AshA2A.Protocol.AgentCard.audit/2`.
   Against the simulation server's card, with its mounts described:

   ```elixir
   {body, 0} = System.cmd("curl", ["-s", "http://127.0.0.1:4190/.well-known/agent-card.json"])
   card = Jason.decode!(body)

   mounted = [
     bindings: ["JSONRPC", "HTTP+JSON", "GRPC"],
     streaming: true, push_notifications: true, live: true,
     extended_agent_card: true, user_artifacts: true,
     security_schemes: Map.keys(card["securitySchemes"]),
     skill_ids: Enum.map(card["skills"], & &1["id"])
   ]

   AshA2A.Protocol.AgentCard.audit(card, mounted)
   #=> []
   AshA2A.Protocol.AgentCard.audit(card, Keyword.put(mounted, :bindings, ["JSONRPC"])) |> Enum.map(& &1.code)
   #=> [:unmounted_binding, :unmounted_binding]
   ```

   An empty list means the card is honest; each entry names one claim that has no mount
   behind it. See [agent card honesty](../reference/agent-card-honesty.md).
4. To exercise your own agent in tests with the real transports and no mocks, see
   [Test your ash_a2a app](../how-to/test-your-ash_a2a-app.md).

## Where to go next

- [Run the simulation server](../how-to/run-the-simulation-server.md): the skills, tokens and the
  start-from-code form.
- [Check A2A v1.1 parity](../how-to/check-a2a-v1-1-parity.md) and its
  [findings](../reference/a2a-v1-1-parity-findings.md).
- [Choose a reply mode](../how-to/choose-a-reply-mode.md): why `ping` answers a bare Message.
