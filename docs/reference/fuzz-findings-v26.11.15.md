# Wire decoder fuzz findings (v26.11.15)

Status: **UNVERIFIED.** The fuzz tests were written without an Elixir toolchain
and have not been run. The findings below come from reading
`lib/ash_a2a/protocol/json.ex` and `lib/ash_a2a/protocol/jsonrpc/request.ex`,
not from an observed crash. Confirm with `ASH_A2A_FUZZ_STRICT=1 mix test test/fuzz_json_decoders_test.exs`.

## Files

- `test/support/fuzz_gen.ex`: seeded generator (`:rand`, fixed base seed; `stream_data` is already a dependency but was not needed).
- `test/fuzz_json_guard_test.exs`: strict (never raises, never hangs, depth bound, round-trip).
- `test/fuzz_json_decoders_test.exs`: message, task, agent card, list request. Totality tests print raises and fail only under `ASH_A2A_FUZZ_STRICT=1`; hangs and round-trips always fail.
- `test/fuzz_jsonrpc_request_test.exs`: strict. No defect predicted from reading.

## Fixed in scope

- `JSONGuard.decode/2`: an `ArgumentError` from `Jason.decode/1` on an unrepresentable number is now returned as `{:error, %Jason.DecodeError{}}`. Defensive; whether Jason raises here depends on its version (UNVERIFIED).

## Suspected defects in json.ex (not edited; owned by another lane)

Each is a raise instead of `{:error, _}` for well-formed JSON of the wrong type.

1. `decode(map, :task)` / `:message` / `:artifact` with a non-map `map`: `Map.get/2` raises `BadMapError`.
   Repro: `AshA2A.Protocol.JSON.decode(1, :message)`.
2. `decode(%{"messageId" => "m", "role" => "ROLE_USER", "parts" => "x"}, :message)`: `require_non_empty/2` or `decode_list/2` receives a non-list (`Enum.reduce_while` raises `Protocol.UndefinedError`).
3. `decode(%{"parts" => [1]} |> Map.merge(valid_header), :message)`: list item is not a map, so `decode(1, :part)` raises `BadMapError`.
4. `decode(%{"id" => "t", "status" => %{"state" => "TASK_STATE_COMPLETED"}, "history" => 5}, :task)`: `Map.get(map, "history", [])` yields a non-list for `decode_list/2`.
5. `decode(%{"id" => "t", "status" => 5}, :task)`: `decode(5, :status)` raises `BadMapError`.
6. `decode_agent_card/1` with `"skills" => 5`, `"capabilities" => 5` or `"supportedInterfaces" => 5`: the `decode_card_*` helpers are only guarded for the expected types (not confirmed per helper).
7. `decode_list_tasks_request/1` and `decode_agent_card/1` have `is_map` heads, so a non-map raises `FunctionClauseError`; callers must guard.

Round-trip stability (decode, encode, JSON text, decode) is asserted for valid messages and tasks; any divergence will show as a test failure.
