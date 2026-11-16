#!/usr/bin/env bash
# Builds the independent A2A v1.1 reference: a Python venv with the official
# protobuf/gRPC runtime and stubs generated from the upstream v1.1.0-rc proto.
#
#   scripts/a2a_v1_1_parity/setup.sh [VENV_DIR]
#
# VENV_DIR defaults to $A2A_PARITY_VENV, else /tmp/a2a_v1_1_parity/venv.
# Nothing is written inside the repository.
#
# The proto is taken from the upstream clone when A2A_UPSTREAM (default
# /home/user/a2aproject/a2a) holds tag v1.1.0-rc, else from the vendored copy
# priv/a2a_v1_1_spec_corpus/a2a.proto. Either way its SHA-256 must equal the
# pinned digest of v1.1.0-rc:specification/a2a.proto.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VENV="${1:-${A2A_PARITY_VENV:-/tmp/a2a_v1_1_parity/venv}}"
UPSTREAM="${A2A_UPSTREAM:-/home/user/a2aproject/a2a}"
TAG="v1.1.0-rc"
PROTO_SHA256="$(cat "$HERE/a2a.proto.sha256")"
PYTHON="${PYTHON:-python3}"

"$PYTHON" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check -r "$HERE/requirements.txt"

GEN="$VENV/a2a_v1_1_gen"
rm -rf "$GEN"
mkdir -p "$GEN/proto"

if git -C "$UPSTREAM" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  git -C "$UPSTREAM" show "$TAG:specification/a2a.proto" > "$GEN/proto/a2a.proto"
  SOURCE="$UPSTREAM@$TAG:specification/a2a.proto"
else
  cp "$REPO/priv/a2a_v1_1_spec_corpus/a2a.proto" "$GEN/proto/a2a.proto"
  SOURCE="priv/a2a_v1_1_spec_corpus/a2a.proto (vendored)"
fi

ACTUAL="$(sha256sum "$GEN/proto/a2a.proto" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$PROTO_SHA256" ]; then
  echo "a2a.proto from $SOURCE has sha256 $ACTUAL, expected $PROTO_SHA256" >&2
  exit 1
fi

# google/api/*.proto and google/rpc/*.proto ship inside
# googleapis-common-protos; google/protobuf/*.proto inside grpcio-tools.
SITE="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
"$VENV/bin/python" -m grpc_tools.protoc \
  -I "$GEN/proto" -I "$SITE" -I "$SITE/grpc_tools/_proto" \
  --python_out="$GEN" --grpc_python_out="$GEN" "$GEN/proto/a2a.proto"

# The v1.0 half: stubs from v1.0.1, in their own directory (the two protos
# declare the same package, so they are never loaded into one process).
GEN10="$VENV/a2a_v1_0_gen"
rm -rf "$GEN10"
if git -C "$UPSTREAM" rev-parse -q --verify "refs/tags/v1.0.1" >/dev/null 2>&1; then
  mkdir -p "$GEN10/proto"
  git -C "$UPSTREAM" show "v1.0.1:specification/a2a.proto" > "$GEN10/proto/a2a.proto"
  ACTUAL10="$(sha256sum "$GEN10/proto/a2a.proto" | cut -d' ' -f1)"
  if [ "$ACTUAL10" != "$(cat "$HERE/a2a_v1_0.proto.sha256")" ]; then
    echo "v1.0.1 a2a.proto has sha256 $ACTUAL10, expected $(cat "$HERE/a2a_v1_0.proto.sha256")" >&2
    exit 1
  fi
  "$VENV/bin/python" -m grpc_tools.protoc \
    -I "$GEN10/proto" -I "$SITE" -I "$SITE/grpc_tools/_proto" \
    --python_out="$GEN10" --grpc_python_out="$GEN10" "$GEN10/proto/a2a.proto"
  printf '%s\n' "$UPSTREAM@v1.0.1:specification/a2a.proto" > "$GEN10/SOURCE"
  printf '%s\n' "$ACTUAL10" > "$GEN10/SHA256"
  echo "v1.0 reference stubs (sha256 $ACTUAL10) in $GEN10"
else
  echo "no tag v1.0.1 in $UPSTREAM: the v1.0 vectors will be skipped (git fetch --depth 1 origin tag v1.0.1)"
fi

printf '%s\n' "$SOURCE" > "$GEN/SOURCE"
printf '%s\n' "$ACTUAL" > "$GEN/SHA256"
echo "reference stubs for $SOURCE (sha256 $ACTUAL) in $GEN"
