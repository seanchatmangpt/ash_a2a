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
