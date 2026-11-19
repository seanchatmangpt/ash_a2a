# Wire decoder fuzz findings (v26.11.15)

Status: **CLOSED.** Every finding below is fixed and the fuzz suite runs strict
by default: `mix test test/fuzz_*_test.exs` fails on any raising input. Last
run: 0 raising inputs (before the fix the same generator raised on 302 task
inputs, 216 message inputs and 7 agent card inputs).

## Files

- `test/support/fuzz_gen.ex`: seeded generator (`:rand`, fixed base seed; `stream_data` is already a dependency but was not needed).
- `test/fuzz_json_guard_test.exs`: never raises, never hangs, depth bound, round-trip (1,000 iterations).
- `test/fuzz_json_decoders_test.exs`: every `AshA2A.Protocol.JSON` decoder over corrupted fixtures and random terms (2,000 iterations each): `decode/2` for all thirteen types, `decode_agent_card/1`, `decode_list_tasks_request/1`, `decode_send_message_request/1`, `decode_send_message_configuration/1`, `decode_get_task_request/1`, `decode_subscribe_request/1`, `decode_stream_request/1`, `decode_list_result/1`, `decode_state/1`. A raise, a hang or a result outside `{:ok, _}` / `{:error, _}` / `{:skip, _}` fails the test. The `ASH_A2A_FUZZ_STRICT` switch is gone.
- `test/fuzz_jsonrpc_request_test.exs`: JSON-RPC request envelope (1,500 iterations).
- `test/fuzz_transport_decode_test.exs`: the same corrupted messages sent as `message/send` through the real plugs.

## Contract

Every public decoder of `AshA2A.Protocol.JSON` is total: any term in gives
`{:ok, value}` or `{:error, reason}` (`decode(_, :event)` may also give
`{:skip, _}`), never a raise. `decode!/2` raises by design.

- A payload that is not a JSON object is `{:error, {:invalid_field, "<type>"}}`.
- A present member of the wrong JSON type is `{:error, {:invalid_field, "<member>"}}`; an absent required member stays `{:error, {:missing_field, "<member>"}}`.
- An optional member that is absent or JSON `null` takes its default (for example `metadata` is `%{}`, `history` is `[]`).
- An int64 member (`generation`, `lastSeenGeneration`, ...) outside the signed 64-bit range, or given as a string longer than 20 bytes, is ignored rather than parsed.

At the transports a decode refusal is the binding's invalid-argument answer:
JSON-RPC `-32602`, HTTP+JSON `400` `INVALID_ARGUMENT`, gRPC
`INVALID_ARGUMENT(3)`. Before the fix a raising decoder was caught by the
JSON-RPC dispatcher's rescue and answered as `-32603` internal error (HTTP 500
on the REST binding), which blamed the server for a malformed client request.

## Fixed in scope

- `JSONGuard.decode/2`: an `ArgumentError` from `Jason.decode/1` on an unrepresentable number is returned as `{:error, %Jason.DecodeError{}}`.

## Closed defects in json.ex

Each was a raise instead of `{:error, _}` for well-formed JSON of the wrong type.

1. `decode(map, type)` with a non-map `map` (`BadMapError`). Now `{:error, {:invalid_field, "<type>"}}`.
   Repro: `AshA2A.Protocol.JSON.decode(1, :message)`.
2. `"parts" => "x"` in a message or artifact (`Protocol.UndefinedError` / `FunctionClauseError`). Now `{:error, {:invalid_field, "parts"}}`.
3. `"parts" => [1]`: a list item that is not an object. Now `{:error, {:invalid_field, "part"}}`.
4. `"history" => 5`, `"artifacts" => 5`, `"timeline" => 5` or an explicit `null` in a task. Now `{:error, {:invalid_field, _}}` (`null` is the empty list).
5. `"status" => 5` in a task or status update. Now `{:error, {:invalid_field, "status"}}`.
6. `decode_agent_card/1` with a non-object skill, a non-object `provider`, a non-list `defaultInputModes`, or `securityRequirements` entries that are not objects of scope lists. Now `{:error, {:invalid_field, _}}`.
7. `decode_agent_card/1`, `decode_list_tasks_request/1`, `decode_get_task_request/1` and `decode_subscribe_request/1` with a non-map (`FunctionClauseError`). Now `{:error, _}`.
8. A non-string `timestamp`, a non-string `bytes` / `raw`, and a non-list push `authentication.schemes`. Now `{:error, _}` (or ignored for `schemes`).
9. A multi-megabyte digit string in an int64 member was parsed into a bignum. Now ignored.

Wrong-typed scalar members (`contextId`, `taskId`, `metadata`, `name`, `text`,
`final`, `append`, ...) used to be copied into the struct unchecked and raised
later in the code that consumed it; they are now refused at decode.

Round-trip stability (decode, encode, JSON text, decode) is asserted for valid messages and tasks.


## Wave 2: every other parser and verifier on the wire

`FuzzGen.seed/1` now adds the `FUZZ_SEED` environment offset (default 0), so
`FUZZ_SEED=3 mix test test/fuzz_sse_test.exs` re-runs a file on a different
stream; `FuzzGen.iterations/1` scales a file's CI default with `FUZZ_ITERATIONS`
(a percentage, default 100). Each new file stays under about 10 s at the default.
Every new file was also run with `FUZZ_SEED=1..10`: 41 tests, all green each time.

| File | Target |
|---|---|
| `test/fuzz_grpc_framing_test.exs` | `Transport.Grpc.Framing`: truncated header, length beyond the buffer, length 2^32-1, compressed flag without a codec, unknown flags, empty stream, 50,000 tiny frames, random chunking, trailers |
| `test/fuzz_sse_test.exs` | `Protocol.Client.SSE`: parse(chunked(x)) == parse(x) for random chunkings and at every split point, CR/LF/CRLF, BOM, comments, `id`/`retry`/`event`, multi-line data, huge lines, the transports' frame shape |
| `test/fuzz_email_test.exs` | `Email.Inbound.parse/1` and `Email.Dkim.verify/2`: every byte of a signed message flipped (3 masks), deletions, insertions, truncation, duplicate tags, folded and 500 KB headers, bad base64, `bh=` mismatch, random maps |
| `test/fuzz_card_signature_test.exs` | `Wire.Jcs` and `AgentCardSignature.verify/3`: RFC 8785 vectors, idempotence, alg confusion, `crit`, `b64:false`, extra segments, non-UTF-8, every byte of a valid entry flipped |
| `test/fuzz_task_store_test.exs` | ETS and Ekv `get`/`list`/`list_all` over corrupted rows; `EventJournal.replay_after/3` (ETS and Ekv) with out-of-order generations and corrupt rows |
| `test/fuzz_http_surface_test.exs` | Real plugs with `Plug.Test`: HTTP+JSON paths (unicode, percent-encoding, double-encoded slashes, `message:send` suffix confusion), query strings (arrays, duplicates, malformed), JSON-RPC batch and envelopes on all three JSON-RPC plugs. Property: no raise, no 5xx, well-formed error body, no stack trace or internal detail |

### Defects found and fixed

1. **`Protocol.Client.SSE` quadratic parsing.** Each `feed/2` re-concatenated, re-normalized and re-split the whole buffer, so a large event delivered in small chunks cost O(n^2) (a 200 KB event one byte at a time did not finish in minutes). The parser now keeps the incomplete event as iodata and does work proportional to the new chunk. Regression: `a 60 KB event delivered one byte at a time is parsed in linear time`.
2. **`Client.SSE` held a trailing CR.** A stream ending `...\r\r` withheld its last event until another byte arrived. A chunk ending in CR now ends its line immediately and a `\n` opening the next chunk is dropped (CRLF split across chunks is still one break).
3. **`Client.SSE` did not ignore a leading UTF-8 BOM** (WHATWG SSE), even when split across chunks. Now ignored.
4. **`AgentCardSignature.verify/3` and `sign/3` raised `UnicodeConversionError`** on a card containing a non-UTF-8 string or key (the canonicalizer was handed bytes that are not JSON). Now `{:error, :non_canonicalizable_card}`.
5. **`AgentCardSignature` canonicalized integers outside +-(2^53-1)** (no RFC 8785 form; a 5,000-digit integer produced output that is not valid JSON). Now `{:error, :non_canonicalizable_card}`.
6. **`TaskStore.ETS` raised `BadMapError` in `list/2` and `list_all/2`, and `get/2` returned `{:ok, garbage}`,** for a row that is not a task. Rows that are not `%Task{}` are now `:not_found` and absent from listings (the Ekv store already behaved this way).
7. **`AshA2A.A2ATransport.Plug` raised `FunctionClauseError` on a JSON-RPC batch** (a JSON array body): the delegate handed the list to `Protocol.Plug.read_json_body/1`, which only accepted maps. A batch is now handed to `JSONRPC.handle/3` and answered.
8. **`Transport.HTTPJSON` let `Plug.Conn.InvalidQueryError` escape** for a malformed query string (invalid percent-encoding or UTF-8, for example `?a=%FF`), so the host's default error page answered instead of the binding. Now HTTP 400 `INVALID_ARGUMENT`.

### Checked and clean

- gRPC framing: the compiler warning about `len` accessed inside `size(...)` that the brief cites for `framing.ex:118` is already gone at this commit (`take/3` uses `:erlang.split_binary/2` and the frame head match binds `len` once); the lane's regression test `the declared length (not a rebound variable) sizes each chunk` passes and pins the behaviour. The same warning does still exist for `len` in `lib/ash_a2a/attestation/key.ex:146,163` but those matches bind `len` in the same pattern, so they are correct.
- DKIM and inbound email: no defect; every mutated message was refused with an atom reason or accepted with an unchanged meaning, and nothing raised.
- `AgentCardSignature` entries: alg confusion (`none`, `HS256`, case, wrong key type), `crit`, extra segments, padding, non-UTF-8 protected headers, and every flipped byte are refused; a flipped `protected` byte never verifies. Header members `jwk`, `jku`, `x5c` and `b64:false` without `crit` are ignored (keys come only from the caller's keyset), not honoured.
- JSON-RPC batch on `Protocol.Plug` and `Transport.Plug`, and every HTTP+JSON path and query shape: no 5xx, no leak.
