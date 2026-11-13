# Ingress Attestation Reference

Standing: UNVERIFIED

Module reference for the ingress attestation surface, read from
`lib/ash_a2a/attestation/{key,gate,gate_grant_allowlist}.ex` and
`lib/ash_a2a/ingress/channel.ex` on 2026-11-10. Test files:
`test/attestation/attestation_gate_test.exs`,
`test/attestation/gate_grant_allowlist_test.exs`,
`test/ingress/channel_test.exs`. Tests were not run for this page.

Scope: the gate validates signature, freshness and claim consistency. It
does not perform hardware-enclave attestation (Play Integrity, App Attest,
DeviceCheck) and trusts the signing-key holder.

## AshA2A.Attestation.Key

ES256 (ECDSA P-256 + SHA-256) on `:crypto`, no JOSE dependency. Token:
`v1.<base64url(json)>.<base64url(DER signature)>`. Key map:
`%{priv:, pub:, curve: :prime256v1}`.

| function | returns |
|---|---|
| `generate() :: key()` | fresh keypair |
| `sign(map(), key()) :: token() \| {:error, term()}` | signed token; `{:error, :bad_key}` on bad key |
| `verify(token(), key()) :: {:ok, map()} \| {:error, reason}` | claims map |

`verify/2` errors: `:bad_signature`, `:non_canonical_signature`,
`:malformed_token`. `sign/2` normalizes to low-s; `verify/2` refuses
`s > n/2` (malleated twin) as `:non_canonical_signature`. Structurally
broken DER is `:bad_signature`.

## AshA2A.Attestation.Gate

Refusal type: `{:refused, :bad_signature | :emulator_detected | :stale |
:spoofed_payload | :gps_impossible_jump | :malformed_token | :clock_skew |
:nonce_mismatch | :non_canonical_signature}`.

| function | returns |
|---|---|
| `verify_enclave({token, nonce}, key \| [key: key])` | `{:ok, claims}` or refused |
| `verify_freshness(claims, opts \\ [])` | `:ok`, `{:refused, :stale \| :clock_skew \| :malformed_token}` |
| `verify_sensor_metadata(claims, opts \\ [])` | `:ok`, `{:refused, :spoofed_payload \| :stale \| :clock_skew}` |
| `verify_gps_trajectory(observations)` | `:ok`, `{:refused, :gps_impossible_jump \| :spoofed_payload}` |
| `verify_gps_trajectory(observations, opts)` | same, with grant override |

Options (freshness, sensor metadata): `:max_staleness_sec` (default 90),
`:now` (default wall clock). Constants: future skew accepted up to 5 s;
jump threshold 500 km within 60 s; GPS accuracy bound 0 < accuracy <=
100_000 m. `verify_enclave/2` fails `:nonce_mismatch` when the claims'
`"nonce"` differs from the supplied nonce, and `:emulator_detected` on
`is_virtual == true`, an `os_fingerprint` matching
`emulator|generic|sdk_gphone|vbox|qemu`, or a known emulator package.

### verify_gps_trajectory/2 grant override

Opts: `:approved_grants` (list of grant maps, default `[]`), `:now`,
`:org_id`, `:identifier`. Only `:gps_impossible_jump` can be overridden:
when the base check refuses with it, `GateGrantAllowlist.override?/4`
decides; `:ok` replaces the refusal, anything else keeps it.
`:spoofed_payload` is never overridden. With no grants the result equals
`verify_gps_trajectory/1`.

## AshA2A.Attestation.GateGrantAllowlist

Consumes grant maps hand-pinned to xaas `ApprovalGeofenceExceptionGrant`
fields (xaas is not imported).

Grant: `%{grant_id:, org_id:, identifier_or_cidr:, ttl_hours:,
approved_at:, area: %{"lat", "lon", "radius_km"}}`. Expiry is
`approved_at + ttl_hours * 3600`.

| function | returns |
|---|---|
| `override?(observations, grants, now)` | `:ok \| {:refused, :gps_impossible_jump}` |
| `override?(observations, grants, now, opts)` | same; `:org_id`, `:identifier` restrict grants carrying those fields |

`:ok` only when every impossible-jump pair falls inside at least one
unexpired, in-scope grant area; expired, out-of-area or empty grants
refuse.

## AshA2A.Ingress.Channel

Pure intake: state in, state out.

| function | returns |
|---|---|
| `empty_state()` | `%{last_known: %{}, consumed_nonces: %{}, refusals: %{}}` |
| `ingest(state, event, opts)` | `{{:ok, validated_event} \| {:refused, reason}, state}` |
| `stats(state)` | per-reason refusal counts |

`ingest/3` opts: `:key` (required), `:now`, `:max_staleness_sec`,
`:approved_grants`, `:org_id`, `:identifier`. Event keys: `:coordinator`,
`:nonce`, `:device_token`, `:timestamp`, `:gps`, `:camera_make`,
`:camera_model`. Check order: shape, nonce replay, signature/enclave,
claims-to-event binding, token freshness, sensor metadata, event time,
trajectory (against last known fix).

Refusal vocabulary (closed, eight): `:bad_signature`, `:stale`,
`:clock_skew`, `:non_canonical_signature`, `:spoofed_payload`,
`:emulator_detected`, `:gps_impossible_jump`, `:nonce_replayed`.
`:nonce_mismatch`, `:malformed_token` and any unrecognized reason fold to
`:spoofed_payload`.

Replay ledger: per coordinator, FIFO, 1024 nonces; recorded on accepted
events only. Binding: when signed claims carry `gps` (`lat`, `lon`,
`accuracy`), `camera_make` or `camera_model`, event copies must match.

## See Also

- [Copilot membrane](../explanation/copilot-membrane.md)
- [Run the Copilot pipeline](../how-to/run-the-copilot-pipeline.md)
- [Module coverage](module-coverage.md)
