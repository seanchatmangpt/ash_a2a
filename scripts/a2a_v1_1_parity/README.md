# A2A v1.1 parity check

Checks that a running ash_a2a simulation server puts A2A v1.1 on the wire,
byte for byte, against a reference that shares no code with ash_a2a.

The reference is the upstream specification itself:

- `specification/a2a.proto` at tag `v1.1.0-rc` of `a2aproject/a2a`
  (SHA-256 in `a2a.proto.sha256`; the vendored
  `priv/a2a_v1_1_spec_corpus/a2a.proto` has the same digest).
- Python stubs generated from it by `grpcio-tools`.
- The official protobuf runtime as encoder and parser.

## Set up

```console
scripts/a2a_v1_1_parity/setup.sh
```

This creates a virtual environment in `/tmp/a2a_v1_1_parity/venv` (pass a
directory, or set `A2A_PARITY_VENV`, to put it elsewhere), installs the pinned
`requirements.txt`, and generates the stubs into the environment. Nothing is
written inside the repository. It needs Python 3.10 or later and access to
PyPI. The proto comes from the upstream clone named by `A2A_UPSTREAM` when it
has the tag, otherwise from the vendored copy; either way its digest must
match.

## Run

Through Mix, which boots the server on free ports and passes them on:

```console
mix ash_a2a.sim --parity            # the matrix; exit 1 on any unexpected mismatch
mix ash_a2a.sim --parity --strict   # known defects fail too
mix ash_a2a.sim --parity --json     # the JSON report
mix test test/ash_a2a/sim/sim_parity_v1_1_test.exs
```

Against a server you started yourself (`mix ash_a2a.sim --http-port 47101 --grpc-port 47102`):

```console
/tmp/a2a_v1_1_parity/venv/bin/python scripts/a2a_v1_1_parity/parity.py \
  --http http://127.0.0.1:47101 --grpc 127.0.0.1:47102 \
  --known scripts/a2a_v1_1_parity/known_defects.json --report /tmp/parity.json
```

| Exit status | Meaning |
| --- | --- |
| `0` | Every row passes. |
| `1` | A row fails. |
| `3` | The only failing rows are known defects (`--known`). |
| `2` | The reference stubs are missing: run `setup.sh`. |

Without `--known` every mismatch is a failure. `--trace` prints each row to
standard error as it is recorded; `--only grpc` and `--groups live,errors`
narrow a run while debugging.

## What it checks

Each row of the matrix is one check of one vector on one binding.

| Check | gRPC | HTTP+JSON and JSON-RPC |
| --- | --- | --- |
| `strict` | The upstream class parses the raw response bytes and finds no unknown field, at any depth. | `json_format.ParseDict(..., ignore_unknown_fields=False)` accepts the body: a misnamed, extra or wrong-typed member fails. The JSON-RPC envelope must hold exactly `jsonrpc`, `id` and `result` or `error`. |
| `wire` | Re-serialising the parsed message gives the bytes the server sent. | The reference re-emits the message with `MessageToJson`; its RFC 8785 form must equal the RFC 8785 form of what the server sent. |
| `required` | Every field the proto marks `REQUIRED` is set (spec 5.7). | The same. |
| `semantics` | The answer has the v1.1 behaviour the spec states: `generation`, `timeline`, stream ordering, `lastSeenGeneration`, `SendLiveMessage`, `ifGenerationMatch`, `userArtifacts`. | The same. |
| `error` | The gRPC status and the `google.rpc.ErrorInfo` in `grpc-status-details-bin`. | The HTTP status, `error.status` and `details[]`; or the JSON-RPC `code` and `data[]`. Compared with spec 5.4, 9.5, 10.6 and 11.6. |
| `identical` | One task read over all three bindings is the same upstream `Task`, byte for byte. | |
| `coverage` | Every RPC is called on each binding; every field reachable from a response is observed set, or listed with the reason it cannot be. | |

The gRPC client is the generated `A2AServiceStub`. The HTTP+JSON client reads
the verb, path and body rule of each RPC from its `google.api.http` option in
the proto. The JSON-RPC client uses the RPC name as the method and the
ProtoJSON of the upstream request message as `params`. Push notification
payloads are received by a webhook the script runs itself.

## Normalisations

The comparison applies these and no others. They are also in the JSON report
(`normalisations`).

| What | How | Why it hides no defect |
| --- | --- | --- |
| JSON member order and whitespace | Both sides are written as RFC 8785 before comparing. | JSON objects are unordered; ProtoJSON fixes no order. |
| Number spelling | RFC 8785 number form on both sides. | It only affects doubles inside `google.protobuf.Value` (`12` and `12.0` are one number). 64-bit integer fields are strings in ProtoJSON and are compared as strings. |
| `REQUIRED` fields at their zero value | The reference emits a `REQUIRED` field even when it holds the zero value. | Spec 5.7 says a `REQUIRED` field must be present, and the spec's ListTasks example (6.5) carries `"nextPageToken": ""`. Every other default-valued field must be omitted, as the reference does. |
| JSON-RPC envelope | Only `result` is compared with the reference; the envelope is checked member by member. | The envelope is JSON-RPC 2.0, not a protobuf message. |
| HTTP error envelope | `code`, `status`, `message` are checked one by one; each `details[]` entry is parsed as `google.protobuf.Any` and compared with its re-emission. | Spec 11.6 adds `status` to `google.rpc.Status`, so the object is not a message the reference can round-trip whole. |
| HTTP 204 for a delete | An empty 204 body is accepted as `google.protobuf.Empty`. | Spec 3.1.10: the confirmation of a delete is implementation-specific. |
| Protobuf map entry order | When the gRPC bytes differ, both sides are compared again with the entries of each `map<>` field sorted. Every other byte stays as sent. | The protobuf encoding leaves map order undefined, and the Python runtime's deterministic order is not lexicographic. |

| Agent Card signature bytes | The `signature` of each card signature is blanked in the cross-binding comparison only. | ECDSA signatures are randomised per answer; the prover verifies each one. |

Two `SendLiveMessage` vectors (a later `subscribe`, a message naming another
task) run over gRPC only. Over HTTP each request is its own call and opens
its own stream (spec 3.1.12), so there is nothing to reject. The report lists
them under `not_applicable`.

Enum spelling, camelCase names, int64-as-string, timestamp format,
default-value emission, `null` members, unknown and duplicate members,
protobuf field order and unknown protobuf fields are compared as sent.

## Known defects

`known_defects.json` lists the failing rows that are documented library
defects. Each entry names a finding in
[`docs/reference/a2a-v1-1-parity-findings.md`](../../docs/reference/a2a-v1-1-parity-findings.md),
which states the defect, how to reproduce it and what the wire should carry.
An entry that no longer matches a failing row fails the run, so remove it when
the defect is fixed.

## Files

| File | Contents |
| --- | --- |
| `setup.sh` | Creates the virtual environment and generates the stubs. |
| `requirements.txt` | The pinned Python packages. |
| `a2a.proto.sha256` | The digest the reference proto must have. |
| `reference.py` | The reference encoder, the RFC 8785 writer and the proto facts. |
| `harness.py` | The three clients and the byte-level checks. |
| `parity.py` | The vectors, the matrix and the JSON report. |
| `parity_v1_0.py` | The vectors sent with `A2A-Version: 1.0`, compared with stubs from the upstream `v1.0.1` proto (`a2a_v1_0.proto.sha256`). `parity.py` runs it in its own process and reports its rows under the binding `v1.0`. |
| `known_defects.json` | The known-defect rows. |
