# a2a-error-mapping-decisions

Standing: VERIFIED for the applied mapping (2026-11-16, Elixir 1.20.4 / OTP 29.1.1: `mix test
test/error_version_table_test.exs test/http_json_error_status_table_test.exs`). The TCK source lines cited below were not re-read:
no TCK checkout exists in this environment.

## Decision 1: -32005 and -32006 HTTP status

Decided on 2026-11-16: the specification's table is followed. `docs/specification.md` section 5.4
states the HTTP status of every A2A error type, with the same text at tags `v1.0.1` and
`v1.1.0-rc`:

| code | name | HTTP | gRPC | JSON-RPC |
|---|---|---|---|---|
| -32002 | TaskNotCancelable | 400 | FAILED_PRECONDITION (9) | -32002 |
| -32005 | ContentTypeNotSupported | 400 | INVALID_ARGUMENT (3) | -32005 |
| -32006 | InvalidAgentResponse | 500 | INTERNAL (13) | -32006 |

An earlier revision of this decision followed values recorded from a TCK checkout (409, 415 and
502) because the proto file alone states no HTTP status. The specification document does, in both
versions, so those values are gone from the library: the HTTP+JSON binding serves the table and
`AshA2A.Protocol.JSONRPC.Error.spec_http_status/1` returns it. The one table is
`AshA2A.Protocol.JSONRPC.Error.bindings/1`; the transports generate their status mappings from it.
A TCK run that still pins the older values will disagree until the TCK follows the specification.
Closed as VG-01..VG-03 in [parity findings](a2a-v1-1-parity-findings.md).

## Decision 2: absent protocol version

Rule: an absent version is `"0.3"` everywhere (spec section 3.6.2; `Version.parse_header/1`).
`PushDelivery.payload_for/3` now defaults a config without `protocol_version` to `"0.3"` instead
of `"1.0"`. Behaviour is unchanged in effect, because both are below 1.1 and strip the v1.1-only
fields; only the documented default now matches the header gate. `AshA2A.Protocol.Version`'s
`@default "1.0"` is outside this lane and untouched.

## See Also

- test/error_version_table_test.exs
