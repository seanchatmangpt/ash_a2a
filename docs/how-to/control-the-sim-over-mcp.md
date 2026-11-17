# How to control the simulation server over MCP

`mix ash_a2a.sim.mcp` puts a Model Context Protocol server in front of the
[simulation server](run-the-simulation-server.md). An MCP client (Claude Code,
or any client that speaks MCP) then drives every A2A operation through tools:
it sends messages, streams, cancels, subscribes, manages push configs, reads
the agent card, and reads the Ash rows to confirm what a call changed.

Every wire tool sends a real request to a real listener and answers the
status, the headers and the exact body it received.

The server implements MCP revision `2025-11-25` and also negotiates
`2025-06-18` and `2025-03-26`.

## Connect Claude Code

The repository root holds `.mcp.json`, which registers the stdio server:

```json
{
  "mcpServers": {
    "a2a-sim": {"type": "stdio", "command": "bin/a2a-sim-mcp", "args": []}
  }
}
```

Open Claude Code in the repository and approve the `a2a-sim` server. Its
tools appear as `mcp__a2a-sim__<tool>`.

`bin/a2a-sim-mcp` boots the simulation server on free ports in its own VM and
serves MCP on stdio until its input closes.

## Run it yourself

```console
bin/a2a-sim-mcp                       # stdio
bin/a2a-sim-mcp --http 4000           # Streamable HTTP at http://127.0.0.1:4000/mcp
MIX_ENV=test mix ash_a2a.sim.mcp      # stdio, without the wrapper
```

In stdio mode an MCP client reads standard output as protocol, so nothing but
MCP messages may be written there. `bin/a2a-sim-mcp` makes that certain: it
hands the real standard output to the MCP transport as file descriptor 3 and
points descriptor 1 at standard error, so compiler output and logs cannot
reach the client. If you run `mix ash_a2a.sim.mcp` directly, compile first
(`MIX_ENV=test mix compile`); the task sends the logger to standard error
itself.

| Environment variable | Effect on `bin/a2a-sim-mcp` |
| --- | --- |
| `A2A_SIM_MCP_LOG` | append standard error to this file |
| `A2A_SIM_MCP_ENV` | source this file first (to put `mix` on `PATH`) |
| `A2A_SIM_MCP_DIRECT` | `1` skips the launcher shim and runs `mix` directly |
| `A2A_SIM_MCP_CACHE` | the shim's cache file (default `_build/a2a_sim_mcp_cache.json`, or under `MIX_BUILD_PATH`) |
| `A2A_SIM_MCP_INIT_WAIT` / `A2A_SIM_MCP_LIST_WAIT` | seconds `initialize` / `tools/list` wait for the real server when there is no cache (defaults 15 / 20) |

`--sim-http-port`, `--sim-grpc-port` and `--sim-push-port` pin the ports of
the simulation server; each defaults to a free port.

## Why it attaches quickly: the launcher shim

An MCP client gives up on a server that has not answered `initialize` within
its connect budget (30 s in Claude Code). A stale or cold build needs longer
than that to compile. In stdio mode `bin/a2a-sim-mcp` therefore starts
`scripts/mcp_shim.py` (Python 3, standard library only), which starts the real
server in the background and meanwhile:

- answers `initialize`, `ping`, `tools/list` and `resources/list` from the
  cache written by the last healthy start (refreshed on every healthy start);
- with no cache, waits up to `A2A_SIM_MCP_INIT_WAIT` seconds for the real
  server, then answers a minimal `initialize` and, after
  `A2A_SIM_MCP_LIST_WAIT` seconds, an empty tool list, and sends
  `notifications/tools/list_changed` when the real server is up (the shim
  always declares `tools.listChanged: true`);
- holds every other request until the real server serves, then proxies all
  traffic byte for byte in both directions, ids untouched;
- if the server cannot start (a compile error), answers each held and later
  request with a JSON-RPC error `-32603` that quotes the compile output.

`bin/a2a-sim-mcp --http PORT` and `A2A_SIM_MCP_DIRECT=1 bin/a2a-sim-mcp` do
not use the shim.

## The tools

| Tools | What they do |
| --- | --- |
| `jsonrpc_*`, `http_*`, `grpc_*` | One tool per served JSON-RPC method, HTTP+JSON route and gRPC RPC, derived from `AshA2A.Sim.Surface`. Each takes that binding's own request: `params`, a `body` and path parameters, or a protobuf JSON `request`. |
| `a2a_send_message`, `a2a_stream_message`, `a2a_live_message` | Run a skill. `binding` picks `jsonrpc`, `http_json` or `grpc`. |
| `a2a_get_task`, `a2a_list_tasks`, `a2a_cancel_task`, `a2a_subscribe_task` | Read, list, cancel and follow tasks. `a2a_subscribe_task` takes `last_seen_generation` to resume. |
| `a2a_create_push_config`, `a2a_get_push_config`, `a2a_list_push_configs`, `a2a_delete_push_config` | Manage a task's webhooks. |
| `a2a_get_agent_card`, `a2a_get_extended_agent_card` | Read the public and the authenticated card. |
| `a2a_raw_request` | Send bytes you wrote: a malformed JSON body, a gRPC call with garbage protobuf, or raw bytes on the TCP socket. |
| `sim_info` | The URLs, ports, bearer tokens and skills of the running server. |
| `sim_grant_authority`, `sim_revoke_authority` | Issue or revoke the standing grant a mutating skill needs. |
| `sim_read_rows` | Read `AshA2A.Sim.Note` from the data layer, and the recorded publications. |
| `sim_push_deliveries` | What the webhook receiver recorded. |
| `sim_email_issue_brief` | File an email brief (two numbered actions with reply tokens) and get the DKIM key facts, the webhook secret and the ingest URLs. |
| `sim_email_send_reply` | POST to the email gateway: a canned `scenario` (every outcome), a reply the tool builds and DKIM-signs for `brief_id`, or a signed `raw` message you supply. It reports the status, the body and whether an Ash row changed. |
| `sim_email_deliveries` | The mail the email gateway sent (receipt summaries, reconfirm briefs) and the requests it answered. |
| `sim_surface` | The served surface, with the tools that reach each item. |
| `sim_coverage` | A runnable plan: the tool calls that reach each surface item and what each must answer. |
| `sim_prove` | Run `AshA2A.Sim.Prover` and return its matrix. |
| `sim_parity` | Run the byte-for-byte A2A v1.1 parity script (`AshA2A.Sim.Parity`) and return one verdict per binding, the counts and the failing rows. `binding` narrows it, `strict` counts known defects as failures. |

Every wire tool also takes:

- `a2a_version` — the `A2A-Version` to send. Defaults to `1.1`; `none` omits it.
- `token` — `writer` (holds the grants), `reader` (no grants), `unscoped`
  (lacks the `a2a:invoke` scope), `none`, or a literal bearer token. Any token
  that starts with `sim-agent-` authenticates as a caller of its own with no
  grants, so you can issue and revoke grants for it without touching the
  fixed identities.
- `timeout_ms` and `headers`.

A wire tool answers `status` (the HTTP status, or the gRPC status code),
`headers`, `trailers`, `body` (the response body as text), `body_base64`
(set when the body is not UTF-8, and for gRPC replies the protobuf bytes),
`json`, and `frames` (every stream response of a server-sent event or gRPC
stream). It also reads the common fields out for you: `task`, `state`,
`states`, `final_state`, `frame_kinds`, `data`, `config`, `configs`, `error`
and `ok`.

A tool call that the A2A server refuses is still a successful tool call: the
refusal is the result. `isError` is `true` only when the tool could not run,
for example when the arguments do not match its `inputSchema`.

When a `tools/call` request carries a progress token, each stream response is
also sent as a `notifications/progress` message while the stream runs. Over
Streamable HTTP, a `tools/call` from a client that accepts
`text/event-stream` is answered as an event stream.

## Resources

| URI | Content |
| --- | --- |
| `a2a://agent-card` | the public agent card, fetched from the server |
| `sim://info` | the result of `sim_info` |
| `sim://surface` | the surface inventory |
| `sim://coverage` | the whole coverage plan |
| `sim://prover/matrix` | the matrix of the last `sim_prove` call |

## Confirm a mutation

1. Call `a2a_send_message` with `{"binding": "jsonrpc", "skill": "create_note", "data": {"title": "hello"}}`.
   The result's `state` is `TASK_STATE_COMPLETED` and `data.id` is the new row's id.
2. Call `sim_read_rows` with `{"title": "hello"}`. The row is there.
3. Call `a2a_send_message` again with `"token": "reader"`. The `state` is
   `TASK_STATE_REJECTED` and `sim_read_rows` shows no second row.

## Operate by email

The server mounts the email gateway (see [Operate by email](operate-by-email.md)
and [How to run the simulation server](run-the-simulation-server.md)). Approve
a brief the way an operator would:

1. Call `sim_email_issue_brief` with `{}`. It answers `brief_id`, `title`, the
   `reply_tokens` and the `dkim` facts the gateway trusts.
2. Call `sim_email_send_reply` with `{"brief_id": "<brief_id>"}`. The tool signs
   a reply (rsa-sha256, relaxed/relaxed) and POSTs it. The result has
   `status` `200`, `landed` `true` and `json.results.0.standing`
   `dispatched`. `{"build_only": true}` returns the signed `raw` message
   without sending it, and `{"raw": "<message>"}` sends one you signed.
3. Call `sim_read_rows` with `{"title": "<title>"}`. The row is there.

Every refusal must leave the rows alone, and `landed` says whether it did.
Add `tamper: "body_byte"` (one byte flipped after signing), `sign: "foreign"`,
`dkim_tags: " l=5;"`, `from_domain: "evil.example"`, `tokens_mode: "none"`,
`from: "other@sim.example"` or `mount: "workspace"` with `auth: "wrong"`, and
the gateway answers `401` or `403` with `landed: false`. `scenario` runs a
whole outcome on its own and answers `as_expected`: for example
`{"scenario": "stale_graph_digest_refused"}`, after which
`sim_email_deliveries` shows the reconfirm brief that was mailed.

## Prove that MCP reaches the whole surface

`AshA2A.Sim.MCP.Coverage` maps every item of `AshA2A.Sim.Surface` to tool
calls: the served items and the `parity:` surfaces. A surface item with no tool path is listed by
`AshA2A.Sim.MCP.Coverage.uncovered/0`, and the test fails.

```console
python3 scripts/mcp_drive.py
```

The script launches `bin/a2a-sim-mcp`, speaks MCP to it as a client, runs the
plan of every surface item through `tools/call`, and prints one row per item:

```text
SURFACE                       TOOL                  BINDING  STATUS  DETAIL
jsonrpc_method:tasks/cancel   jsonrpc_tasks_cancel  jsonrpc  pass    3/3 steps; HTTP 200, TASK_STATE_CANCELED, 625 body bytes
grpc_rpc:SendStreamingMessage grpc_SendStreamingMessage grpc pass    2/2 steps; OK, TASK_STATE_COMPLETED, 7 frames
...
92 surface items served, 92 driven through MCP: 92 pass, 0 fail; 0 uncovered; ...
```

It exits `1` on a failed step, an uncovered surface item, a result that does
not match its tool's `outputSchema`, or a line on standard output that is not
an MCP message.

| Command | What it does |
| --- | --- |
| `python3 scripts/mcp_drive.py --steps` | also prints every tool call of every item |
| `python3 scripts/mcp_drive.py --only grpc_rpc:` | runs the items whose id starts with a prefix |
| `python3 scripts/mcp_drive.py --list` | prints the tool catalog |
| `python3 scripts/mcp_drive.py --call TOOL JSON_ARGS` | calls one tool and prints its result |
| `python3 scripts/mcp_drive.py --read URI` | reads one resource |

The same proof runs as a test, over stdio and over Streamable HTTP:

```console
mix test test/ash_a2a/sim/sim_mcp_test.exs
```

## Troubleshooting

- **The client reports a connect timeout.** Read the server log (below). The
  first start after a pull compiles the project, and with no cache file the
  shim can only answer a minimal handshake after `A2A_SIM_MCP_INIT_WAIT`
  seconds; once one start has been healthy the cache answers instantly. To
  warm the build yourself: `MIX_ENV=test mix compile`.
- **Tools are missing or `tools/call` returns "the a2a-sim server did not
  start".** The message quotes the compile error. Fix it and reconnect.
- **Where the log is.** Standard error of the shim and the server goes to
  the client's MCP log, or to the file in `A2A_SIM_MCP_LOG` when set, for
  example `A2A_SIM_MCP_LOG=/tmp/a2a-sim.log` in the `env` of `.mcp.json`.
  Lines from the shim start with `[a2a-sim-mcp shim]`.
- **Run the same conversation yourself.** `python3 scripts/mcp_drive.py
  --launcher bin/a2a-sim-mcp --list`.
- The shim's behaviour (stale build, warm cache, current build, a build that
  fails to compile) is tested in `test/ash_a2a/sim/sim_mcp_launcher_test.exs`.

## Known limits

- A `sim_revoke_authority` on the `writer` identity makes the prover's
  mutation probes fail until `sim_grant_authority` issues the grant again.
  Any `sim-agent-<name>` token gives you a caller of your own to experiment
  with.
- `sim_parity` needs the Python reference that
  `scripts/a2a_v1_1_parity/setup.sh` installs. Without it the tool answers
  `ran: false` with the reason, and the `parity:` rows of
  `scripts/mcp_drive.py` fail.
- A gRPC reply's `body` is the reply rendered as protobuf JSON and
  `body_base64` is the reply encoded as protobuf. To see the DATA bytes as
  they arrived, use `a2a_raw_request` with `binding: "grpc"`.
