# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""The independent A2A v1.1 reference: upstream message types, the official
protobuf runtime as encoder, and an RFC 8785 canonical JSON writer.

Nothing in this module knows how ash_a2a encodes anything. The only inputs
are the stubs `setup.sh` generated from `v1.1.0-rc:specification/a2a.proto`
and the google.api / google.rpc descriptors that ship with
googleapis-common-protos.
"""

import json
import os
import sys
from decimal import Decimal

GEN = os.environ.get("A2A_PARITY_GEN") or os.path.join(sys.prefix, "a2a_v1_1_gen")
if not os.path.isfile(os.path.join(GEN, "a2a_pb2.py")):
    sys.stderr.write(
        f"no generated reference stubs in {GEN}; run scripts/a2a_v1_1_parity/setup.sh\n"
    )
    sys.exit(2)
sys.path.insert(0, GEN)

from google.api import annotations_pb2, field_behavior_pb2  # noqa: E402
from google.protobuf import descriptor as pb_descriptor  # noqa: E402
from google.protobuf import json_format  # noqa: E402
from google.protobuf import unknown_fields as pb_unknown_fields  # noqa: E402
from google.rpc import error_details_pb2, status_pb2  # noqa: E402,F401

import a2a_pb2 as pb  # noqa: E402
import a2a_pb2_grpc as pb_grpc  # noqa: E402,F401

SERVICE = pb.DESCRIPTOR.services_by_name["A2AService"]
FD = pb_descriptor.FieldDescriptor


def proto_source():
    """Where the stubs came from and the proto's SHA-256 (written by setup.sh)."""
    out = {}
    for name in ("SOURCE", "SHA256"):
        try:
            with open(os.path.join(GEN, name), encoding="utf-8") as fh:
                out[name.lower()] = fh.read().strip()
        except OSError:
            out[name.lower()] = None
    return out


# -- RFC 8785 canonical JSON ---------------------------------------------------


class JsonError(ValueError):
    pass


def _no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise JsonError(f"duplicate object member {key!r}")
        seen[key] = value
    return seen


def _no_constants(name):
    raise JsonError(f"{name} is not JSON")


def loads(text):
    """Strict JSON: no duplicate members, no NaN/Infinity, UTF-8 only."""
    if isinstance(text, (bytes, bytearray)):
        text = bytes(text).decode("utf-8", errors="strict")
    return json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=_no_constants)


def _es6_number(value):
    # ECMAScript Number.prototype.toString, the number form RFC 8785 requires.
    if value != value or value in (float("inf"), float("-inf")):
        raise JsonError("non-finite number")
    if value == 0:
        return "0"
    sign = "-" if value < 0 else ""
    parts = Decimal(repr(abs(value))).as_tuple()
    digits = "".join(map(str, parts.digits))
    n = len(digits) + parts.exponent
    digits = digits.rstrip("0") or "0"
    k = len(digits)
    if k <= n <= 21:
        body = digits + "0" * (n - k)
    elif 0 < n <= 21:
        body = digits[:n] + "." + digits[n:]
    elif -6 < n <= 0:
        body = "0." + "0" * (-n) + digits
    else:
        e = n - 1
        mantissa = digits[0] + ("." + digits[1:] if k > 1 else "")
        body = f"{mantissa}e{'+' if e > 0 else '-'}{abs(e)}"
    return sign + body


def canonical(value):
    """RFC 8785 (JCS) text of a parsed JSON value."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int):
        if abs(value) > 2**53:
            raise JsonError(f"integer {value} is outside the I-JSON exact range")
        return str(value)
    if isinstance(value, float):
        return _es6_number(value)
    if isinstance(value, list):
        return "[" + ",".join(canonical(v) for v in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: k.encode("utf-16-be"))
        return "{" + ",".join(canonical(k) + ":" + canonical(value[k]) for k in keys) + "}"
    raise JsonError(f"not a JSON value: {type(value).__name__}")


def diff(server, reference, path="$", out=None, limit=6):
    """Paths at which two parsed JSON values differ, typed, for the report."""
    out = [] if out is None else out
    if len(out) >= limit:
        return out
    if isinstance(server, dict) and isinstance(reference, dict):
        for key in sorted(set(server) | set(reference)):
            here = f"{path}.{key}"
            if key not in reference:
                out.append(f"{here}: server emits {_show(server[key])}, reference omits it")
            elif key not in server:
                out.append(f"{here}: server omits it, reference emits {_show(reference[key])}")
            else:
                diff(server[key], reference[key], here, out, limit)
    elif isinstance(server, list) and isinstance(reference, list):
        if len(server) != len(reference):
            out.append(f"{path}: server has {len(server)} items, reference {len(reference)}")
        for index, (a, b) in enumerate(zip(server, reference)):
            diff(a, b, f"{path}[{index}]", out, limit)
    elif type(server) is not type(reference) or server != reference:
        if not (_is_number(server) and _is_number(reference) and server == reference):
            out.append(f"{path}: server {_show(server)}, reference {_show(reference)}")
    return out[:limit]


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _show(value):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    kind = type(value).__name__
    return f"{text[:90]}{'…' if len(text) > 90 else ''} ({kind})"


# -- descriptor facts ----------------------------------------------------------


def is_required(field):
    """True when the upstream proto marks the field REQUIRED (spec 5.7)."""
    behaviors = field.GetOptions().Extensions[field_behavior_pb2.field_behavior]
    return field_behavior_pb2.REQUIRED in behaviors


def _is_map(field):
    return (
        field.type == FD.TYPE_MESSAGE
        and field.message_type.GetOptions().map_entry
    )


def _is_repeated(field):
    return field.is_repeated if hasattr(field, "is_repeated") else field.label == FD.LABEL_REPEATED


def _is_wkt(descriptor):
    return descriptor.full_name.startswith("google.protobuf.")


# REQUIRED fields whose zero value is a legitimate answer, with the reason.
# Every other REQUIRED field must be set to a non-default value.
REQUIRED_ZERO_OK = {
    "ListTasksResponse.tasks": "a filter can match no task",
    "ListTasksResponse.next_page_token": "empty on the last page (proto comment; spec 6.5 example)",
    "ListTasksResponse.page_size": "numeric; zero only for an empty page",
    "ListTasksResponse.total_size": "numeric; zero when nothing matches",
}


def _zero_json(field):
    if _is_map(field):
        return {}
    if _is_repeated(field):
        return []
    if field.type == FD.TYPE_STRING:
        return ""
    if field.type == FD.TYPE_BYTES:
        return ""
    if field.type == FD.TYPE_BOOL:
        return False
    if field.type == FD.TYPE_ENUM:
        return field.enum_type.values_by_number[0].name
    if field.type in (FD.TYPE_INT64, FD.TYPE_UINT64, FD.TYPE_SINT64, FD.TYPE_FIXED64, FD.TYPE_SFIXED64):
        return "0"
    if field.type in (FD.TYPE_DOUBLE, FD.TYPE_FLOAT):
        return 0
    if field.type == FD.TYPE_MESSAGE:
        return None
    return 0


def _walk(message, as_json, path, violations, coverage):
    """Applies spec 5.7 to one message and its JSON image, recursively.

    Inserts into `as_json` the zero value of every REQUIRED field the default
    ProtoJSON emission dropped, records REQUIRED violations, and records which
    fields were observed set.
    """
    descriptor = message.DESCRIPTOR
    set_fields = {field.name for field, _ in message.ListFields()}
    for field in descriptor.fields:
        name = f"{descriptor.name}.{field.name}"
        present = field.name in set_fields
        if present:
            coverage.add(name)
        if is_required(field) and not present:
            zero = _zero_json(field)
            if zero is not None:
                as_json[field.json_name] = zero
            if name not in REQUIRED_ZERO_OK:
                violations.append(f"{path}.{field.json_name} is REQUIRED ({name}) and unset")
        if not present or field.type != FD.TYPE_MESSAGE:
            continue
        value = getattr(message, field.name)
        child_json = as_json.get(field.json_name)
        if _is_map(field):
            value_field = field.message_type.fields_by_name["value"]
            if value_field.type == FD.TYPE_MESSAGE and not _is_wkt(value_field.message_type):
                for key in value:
                    _walk(value[key], child_json[str(key)], f"{path}.{field.json_name}[{key}]", violations, coverage)
        elif _is_wkt(field.message_type):
            continue
        elif _is_repeated(field):
            for index, item in enumerate(value):
                _walk(item, child_json[index], f"{path}.{field.json_name}[{index}]", violations, coverage)
        else:
            _walk(value, child_json, f"{path}.{field.json_name}", violations, coverage)


def reference_json(message, coverage=None):
    """The reference JSON of an upstream message, and its REQUIRED violations.

    The encoder is `google.protobuf.json_format.MessageToJson` with its
    defaults: camelCase names, enums by name, 64-bit integers as strings,
    RFC 3339 timestamps, fields at their default value omitted. On top of
    that, a field the proto marks REQUIRED is emitted even at its zero value,
    because spec 5.7 says a REQUIRED field "MUST be present" (the spec's own
    ListTasks example in 6.5 carries `"nextPageToken": ""`).
    """
    as_json = loads(json_format.MessageToJson(message, indent=None))
    violations = []
    _walk(message, as_json, "$", violations, coverage if coverage is not None else set())
    return as_json, violations


def unknown_field_paths(message, path="$"):
    """Paths of every field the upstream descriptor does not know, recursively."""
    found = []
    for unknown in pb_unknown_fields.UnknownFieldSet(message):
        found.append(f"{path}: field number {unknown.field_number} (wire type {unknown.wire_type})")
    for field, value in message.ListFields():
        if field.type != FD.TYPE_MESSAGE:
            continue
        here = f"{path}.{field.name}"
        if _is_map(field):
            if field.message_type.fields_by_name["value"].type == FD.TYPE_MESSAGE:
                for key in value:
                    found += unknown_field_paths(value[key], f"{here}[{key}]")
        elif _is_repeated(field):
            for index, item in enumerate(value):
                found += unknown_field_paths(item, f"{here}[{index}]")
        else:
            found += unknown_field_paths(value, here)
    return found


# -- protobuf wire bytes, map entries in a canonical order ----------------------


def _varint(buf, i):
    shift = value = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, i
        shift += 7


def canonical_wire(buf, descriptor):
    """The same bytes with the entries of every `map<>` field sorted bytewise.

    Nothing else is touched: tags, lengths and scalar payloads are copied as
    sent, so field order, default-value emission, packing and non-minimal
    varints still show up as differences. Map entry order is the one thing
    protobuf leaves undefined on the wire ("deterministic" serialisation is
    only stable within one implementation), so it is the one thing sorted.
    """
    i, segments = 0, []
    while i < len(buf):
        start = i
        tag, i = _varint(buf, i)
        number, wire_type = tag >> 3, tag & 7
        field = descriptor.fields_by_number.get(number)
        if wire_type == 0:
            _, i = _varint(buf, i)
            segment = buf[start:i]
        elif wire_type == 1:
            i += 8
            segment = buf[start:i]
        elif wire_type == 5:
            i += 4
            segment = buf[start:i]
        elif wire_type == 2:
            length, body = _varint(buf, i)
            i = body + length
            payload = buf[body:i]
            if field is not None and field.type == FD.TYPE_MESSAGE:
                payload = canonical_wire(payload, field.message_type)
            segment = buf[start:body] + payload
        else:
            raise ValueError(f"wire type {wire_type} at offset {start}")
        segments.append((number if field is not None and _is_map(field) else None, segment))
    out, run, run_field = [], [], None
    for map_field, segment in segments + [(None, b"")]:
        if map_field is not None and map_field == run_field:
            run.append(segment)
            continue
        out.extend(sorted(run))
        run, run_field = ([segment], map_field) if map_field is not None else ([], None)
        if map_field is None:
            out.append(segment)
    return b"".join(out)


def reachable_fields():
    """Every field of every message reachable from an RPC response type."""
    seen, fields, stack = set(), [], [m.output_type for m in SERVICE.methods]
    while stack:
        descriptor = stack.pop()
        if descriptor.full_name in seen or _is_wkt(descriptor):
            continue
        seen.add(descriptor.full_name)
        for field in descriptor.fields:
            fields.append(f"{descriptor.name}.{field.name}")
            if field.type == FD.TYPE_MESSAGE:
                target = field.message_type
                if _is_map(field):
                    value_field = target.fields_by_name["value"]
                    if value_field.type == FD.TYPE_MESSAGE:
                        stack.append(value_field.message_type)
                else:
                    stack.append(target)
    return sorted(fields)


def request_fields():
    """Every field of every RPC request type, nested request-only types included."""
    response_side = {name.split(".")[0] for name in reachable_fields()}
    seen, fields, stack = set(), [], [m.input_type for m in SERVICE.methods]
    while stack:
        descriptor = stack.pop()
        if descriptor.full_name in seen or _is_wkt(descriptor):
            continue
        seen.add(descriptor.full_name)
        for field in descriptor.fields:
            fields.append(f"{descriptor.name}.{field.name}")
            if field.type == FD.TYPE_MESSAGE and not _is_map(field):
                if field.message_type.name not in response_side or field.message_type.name in (
                    "TaskPushNotificationConfig",
                    "AuthenticationInfo",
                ):
                    stack.append(field.message_type)
    return sorted(set(fields))


def note_request_coverage(message, coverage):
    for field, value in message.ListFields():
        coverage.add(f"{message.DESCRIPTOR.name}.{field.name}")
        if field.type == FD.TYPE_MESSAGE and not _is_map(field) and not _is_wkt(field.message_type):
            for item in value if _is_repeated(field) else [value]:
                note_request_coverage(item, coverage)


def http_rule(method):
    """The primary google.api.http binding of an RPC: (verb, template, body)."""
    rule = method.GetOptions().Extensions[annotations_pb2.http]
    verb = rule.WhichOneof("pattern")
    return verb.upper(), getattr(rule, verb), rule.body
