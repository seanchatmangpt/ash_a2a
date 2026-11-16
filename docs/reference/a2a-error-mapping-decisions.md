# a2a-error-mapping-decisions

Standing: VERIFIED for the applied mapping (2026-11-16, Elixir 1.20.4 / OTP 29.1.1: `mix test
test/error_version_table_test.exs`, 5 passed). The TCK source lines cited below were not re-read:
no TCK checkout exists in this environment.

## Decision 1: -32005 and -32006 HTTP status

Superseded in part on 2026-11-16: `docs/specification.md` section 5.4 at tags `v1.0.1` and
`v1.1.0-rc` does state HTTP statuses (`-32005` is `400 Bad Request`, `-32006` is
`500 Internal Server Error`), and the HTTP+JSON binding (`status_for/1`) now answers those.
`Error.spec_http_status/1` still returns the TCK values below. The open question is tracked as
VG-02 and VG-03 in [parity findings](a2a-v1-1-parity-findings.md).

| code | name | HTTP (old) | HTTP (now) | gRPC | JSON-RPC |
|---|---|---|---|---|---|
| -32005 | ContentTypeNotSupported | 400 | 415 | INVALID_ARGUMENT (3) | -32005 |
| -32006 | InvalidAgentResponse | 500 | 502 | INTERNAL (13) | -32006 |

Evidence: the pinned TCK `/Users/sac/a2a-tck/tck/requirements/base.py` lines 293-307 bind
`ContentTypeNotSupportedError` to 415 and `InvalidAgentResponseError` to 502.
`tck/validators/http_json/error_validator.py` builds `HTTP_JSON_ERROR_STATUS` from those bindings
and compares `actual_status == expected_status`, so the TCK asserts the status. The spec corpus
`priv/a2a_v1_1_spec_corpus/a2a.proto` carries no HTTP status for these errors (no match for
CONTENT_TYPE / INVALID_AGENT / 415 / 502), so the TCK is the only authority and is followed.
gRPC rows already matched the TCK and are unchanged.

Applied in: `@spec_http` (`AshA2A.Protocol.JSONRPC.Error`), `status_for/1`
(`AshA2A.Transport.HTTPJSON`). gRPC dispatch needed only a comment.

## Decision 2: absent protocol version

Rule: an absent version is `"0.3"` everywhere (spec section 3.6.2; `Version.parse_header/1`).
`PushDelivery.payload_for/3` now defaults a config without `protocol_version` to `"0.3"` instead
of `"1.0"`. Behaviour is unchanged in effect, because both are below 1.1 and strip the v1.1-only
fields; only the documented default now matches the header gate. `AshA2A.Protocol.Version`'s
`@default "1.0"` is outside this lane and untouched.

## See Also

- test/error_version_table_test.exs
