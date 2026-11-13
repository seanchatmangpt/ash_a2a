# a2a-error-mapping-decisions

Standing: UNVERIFIED

## Decision 1: -32005 and -32006 HTTP status

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

- test/y4_error_version_table_test.exs
