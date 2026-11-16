# How to check A2A v1.1 parity

The parity check compares what the simulation server puts on the wire with
what the upstream A2A v1.1 specification encodes, byte for byte. The reference
is built from the upstream proto and the official protobuf runtime, not from
this library's codec.

## Install the reference

```console
scripts/a2a_v1_1_parity/setup.sh
```

The script creates a Python virtual environment in
`/tmp/a2a_v1_1_parity/venv` and generates stubs from
`specification/a2a.proto` at tag `v1.1.0-rc`. Set `A2A_PARITY_VENV` to use
another directory, and keep it set when you run the check. You need Python
3.10 or later and access to PyPI.

## Run the check

```console
mix ash_a2a.sim --parity
```

The task boots the simulation server on free ports, runs every vector over
gRPC, HTTP+JSON and JSON-RPC, and prints one row per check followed by the
counts:

```text
BINDING             pass  fail known  skip
agent-card            16     0     0     0
grpc                 259     0    14     0
http+json            264     0     7     2
jsonrpc              235     0     9     0
jsonrpc:/jsonrpc     145     0     7     0
cross-binding          7     0     0     0
coverage               5     0     0     0
total                931     0    37     2
```

The exit status is `1` when a row fails. A `known` row is a mismatch that is
written up in the
[parity findings](../reference/a2a-v1-1-parity-findings.md); add `--strict` to
make those fail as well, and `--json` to get the whole report.

The same check runs as a test, and as the `parity:` rows of
`mix ash_a2a.sim --prove`:

```console
mix test test/ash_a2a/sim/sim_parity_v1_1_test.exs
```

When the virtual environment is missing, the test is skipped, the `parity:`
rows report `skip`, and `mix ash_a2a.sim --parity` exits `2`. Each says which
directory it looked in.

## Read a failing row

```text
http+json | GetTask | by id | wire | $.generation: server 5 (int), reference "5" (str)
```

The columns are the binding, the operation, the vector and the check. A `wire`
row names each JSON path where the server and the reference differ, with the
value and its type on both sides. For gRPC it prints the two byte strings.

To run one binding or one group of vectors against a server you started
yourself, see
[`scripts/a2a_v1_1_parity/README.md`](../../scripts/a2a_v1_1_parity/README.md).
It also lists every normalisation the comparison applies.

## After you fix a defect

Remove its entries from `scripts/a2a_v1_1_parity/known_defects.json` and its
section from the findings. An entry that no longer matches a failing row makes
the run fail, so a stale list is caught.
