# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""Foreign clients for the three A2A bindings, built from the upstream
descriptors only, and the byte-level checks every response goes through.

* gRPC: the generated `A2AServiceStub`, on a channel that keeps the raw
  response bytes next to the parsed message.
* HTTP+JSON: verb, path and body come from each RPC's `google.api.http`
  option in the upstream proto; query parameters are the camelCase ProtoJSON
  names (spec 11.5).
* JSON-RPC: the method is the RPC name (spec 9.1), `params` is the ProtoJSON
  of the upstream request message.
"""

import http.client
import json
import queue
import re
import socket
import threading
import time
import urllib.parse

import grpc
from google.protobuf import any_pb2, json_format, message_factory
from grpc_status import rpc_status

import reference as ref
from reference import pb, pb_grpc

CHECKS = ("strict", "wire", "required")


class Report:
    def __init__(self):
        self.rows = []
        self.coverage = set()
        self.request_coverage = set()
        self.raw_canonical = [0, 0]
        self.trace = None

    def add(self, binding, operation, vector, check, status, detail=""):
        if status is True:
            status = "pass"
        elif status is False:
            status = "fail"
        if self.trace is not None:
            self.trace.write(f"{status:<5} {binding} | {operation} | {vector} | {check} | {detail[:300]}\n")
            self.trace.flush()
        self.rows.append(
            {
                "binding": binding,
                "operation": operation,
                "vector": vector,
                "check": check,
                "status": status,
                "detail": detail,
            }
        )
        return status == "pass"

    def problems(self, binding, operation, vector, problems, count, what):
        """One row per byte-level check, aggregated over `count` messages."""
        for check in CHECKS:
            found = problems.get(check, [])
            detail = f"{count} {what}" if not found else "; ".join(found[:4])
            self.add(binding, operation, vector, check, not found, detail)

    def apply_known(self, defects):
        """Re-labels failing rows that match a known defect; returns the
        entries that matched nothing (stale)."""
        import fnmatch

        stale = []
        for entry in defects:
            hit = False
            for row in self.rows:
                if row["status"] in ("fail", "known") and all(
                    fnmatch.fnmatchcase(row[key], entry.get(key, "*")) for key in ("binding", "operation", "vector", "check")
                ):
                    row["status"] = "known"
                    row["finding"] = entry["finding"]
                    hit = True
            if not hit:
                stale.append(entry)
        return stale

    def summary(self):
        out = {"pass": 0, "fail": 0, "known": 0, "skip": 0}
        for row in self.rows:
            out[row["status"]] += 1
        return out


def merge(into, problems, prefix=""):
    for check, found in problems.items():
        into.setdefault(check, []).extend(prefix + item for item in found)


# -- the byte-level checks -----------------------------------------------------


def check_pb(report, raw, cls):
    """gRPC: parse the wire bytes with the upstream class, re-serialise
    deterministically, require the same bytes, no unknown field, REQUIRED set."""
    problems = {}
    message = cls()
    try:
        message.ParseFromString(raw)
    except Exception as exc:  # DecodeError
        return None, {"strict": [f"upstream {cls.DESCRIPTOR.name} cannot parse the bytes: {exc}"]}
    unknown = ref.unknown_field_paths(message)
    if unknown:
        problems["strict"] = [f"unknown field at {item}" for item in unknown]
    again = message.SerializeToString(deterministic=True)
    if again != raw and ref.canonical_wire(again, cls.DESCRIPTOR) != ref.canonical_wire(raw, cls.DESCRIPTOR):
        problems["wire"] = [
            f"{len(raw)} bytes on the wire, reference re-serialises to {len(again)}: "
            f"wire {raw.hex()[:120]} reference {again.hex()[:120]}"
        ]
    _json, violations = ref.reference_json(message, report.coverage)
    if violations:
        problems["required"] = violations
    return message, problems


def check_json(report, value, cls):
    """JSON bindings: strict ProtoJSON parse into the upstream class, re-emit
    with the reference encoder, require identical RFC 8785 bytes."""
    problems = {}
    message = cls()
    try:
        json_format.ParseDict(value, message, ignore_unknown_fields=False)
    except Exception as exc:  # ParseError
        return None, {"strict": [f"upstream {cls.DESCRIPTOR.name} rejects the JSON: {exc}"]}
    expected, violations = ref.reference_json(message, report.coverage)
    try:
        if ref.canonical(value) != ref.canonical(expected):
            problems["wire"] = ref.diff(value, expected) or ["canonical bytes differ"]
    except ref.JsonError as exc:
        problems["wire"] = [str(exc)]
    if violations:
        problems["required"] = violations
    return message, problems


def note_raw_canonical(report, body, value):
    """Counts bodies whose bytes already are their RFC 8785 form (informational)."""
    report.raw_canonical[1] += 1
    try:
        if ref.canonical(value).encode("utf-8") == body.strip():
            report.raw_canonical[0] += 1
    except ref.JsonError:
        pass


# -- errors --------------------------------------------------------------------


class ErrorView:
    """One error answer, reduced to what the spec states for its binding."""

    def __init__(self, binding, code, message, details, http_status=None, status_name=None, problems=None, raw=None):
        self.binding = binding
        self.code = code
        self.message = message
        self.details = details
        self.http_status = http_status
        self.status_name = status_name
        self.problems = problems or []
        self.raw = raw

    @property
    def error_infos(self):
        out = []
        for detail in self.details:
            info = ref.error_details_pb2.ErrorInfo()
            if detail.Is(info.DESCRIPTOR):
                detail.Unpack(info)
                out.append(info)
        return out

    def describe(self):
        infos = ",".join(f"{i.reason}@{i.domain}" for i in self.error_infos) or "no ErrorInfo"
        http = f"HTTP {self.http_status} " if self.http_status else ""
        status = f" {self.status_name}" if self.status_name else ""
        return f"{http}{self.code}{status} [{infos}] {self.message!r}"


def _details_from_json(items, problems):
    """`details`/`data`: an array of ProtoJSON `Any` objects (spec 9.5, 11.6)."""
    out = []
    if items is None:
        return out
    if not isinstance(items, list):
        problems.append(f"error details are {type(items).__name__}, the spec says an array")
        return out
    for index, item in enumerate(items):
        if not isinstance(item, dict) or "@type" not in item:
            problems.append(f"details[{index}] has no @type key")
            continue
        detail = any_pb2.Any()
        try:
            json_format.ParseDict(item, detail, ignore_unknown_fields=False)
        except Exception as exc:
            problems.append(f"details[{index}] is not a ProtoJSON Any the reference accepts: {exc}")
            continue
        again = ref.loads(json_format.MessageToJson(detail, indent=None))
        if ref.canonical(again) != ref.canonical(item):
            problems.append(f"details[{index}] differs from the reference: {ref.diff(item, again)}")
        out.append(detail)
    return out


# -- HTTP ----------------------------------------------------------------------


class HttpResponse:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def json(self):
        return ref.loads(self.body)

    @property
    def content_type(self):
        return self.headers.get("content-type", "")


def _connect(url, timeout):
    parts = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=timeout)
    path = parts.path + (f"?{parts.query}" if parts.query else "")
    return conn, path


def http_call(method, url, headers, body=None, timeout=30):
    conn, path = _connect(url, timeout)
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        return HttpResponse(resp.status, {k.lower(): v for k, v in resp.getheaders()}, data)
    finally:
        conn.close()


class SseStream:
    """An open `text/event-stream` response read on a thread.

    `events` holds the `data` of each dispatched event; `fields` the set of
    SSE field names the server used; `response` is set when the server did
    not answer with an event stream at all.
    """

    def __init__(self, method, url, headers, body, timeout=30):
        self.queue = queue.Queue()
        self.events = []
        self.fields = set()
        self.response = None
        self.status = None
        self.headers = {}
        self.closed_by_server = False
        self.error = None
        self._conn, path = _connect(url, timeout)
        self._conn.request(method, path, body=body, headers=headers)
        self._sock = self._conn.sock
        self._resp = self._conn.getresponse()
        self.status = self._resp.status
        self.headers = {k.lower(): v for k, v in self._resp.getheaders()}
        if "text/event-stream" not in self.headers.get("content-type", ""):
            self.response = HttpResponse(self.status, self.headers, self._resp.read())
            self.closed_by_server = True
            self._conn.close()
            self.queue.put(None)
            return
        self._thread = threading.Thread(target=self._read, daemon=True)
        self._thread.start()

    def _read(self):
        data = []
        try:
            while True:
                line = self._resp.readline()
                if not line:
                    self.closed_by_server = True
                    break
                line = line.decode("utf-8").rstrip("\r\n")
                if line == "":
                    if data:
                        event = "\n".join(data)
                        self.events.append(event)
                        self.queue.put(event)
                    data = []
                elif line.startswith(":"):
                    self.fields.add(":comment")
                else:
                    name, _, value = line.partition(":")
                    self.fields.add(name)
                    if name == "data":
                        data.append(value[1:] if value.startswith(" ") else value)
        except Exception as exc:  # socket closed under us, timeout
            self.error = exc
        finally:
            self.queue.put(None)

    def next(self, timeout=15):
        """The next event's data, or None at end of stream or on timeout."""
        try:
            return self.queue.get(timeout=timeout)
        except queue.Empty:
            return None

    def close(self):
        # Shut the socket down first: closing the response while the reader
        # thread sits in readline() would wait on the buffer's lock forever.
        try:
            if self._sock is not None:
                self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        thread = getattr(self, "_thread", None)
        if thread is not None:
            thread.join(timeout=5)
        try:
            self._conn.close()
        except Exception:
            pass


# -- bindings ------------------------------------------------------------------


class Outcome:
    def __init__(self, message=None, error=None, http=None, raw=None):
        self.message = message
        self.error = error
        self.http = http
        self.raw = raw

    @property
    def ok(self):
        return self.message is not None and self.error is None


class StreamResult:
    def __init__(self):
        self.frames = []
        self.error = None
        self.closed = False
        self.problems = {}
        self.http = None
        self.notes = []

    def kinds(self):
        return [frame.WhichOneof("payload") for frame in self.frames]


def frame_generation(frame):
    kind = frame.WhichOneof("payload")
    if kind in ("task", "status_update", "artifact_update", "message_update"):
        return getattr(frame, kind).generation
    return None


def frame_state(frame):
    kind = frame.WhichOneof("payload")
    if kind == "task":
        return frame.task.status.state
    if kind == "status_update":
        return frame.status_update.status.state
    return None


TERMINAL = (
    pb.TASK_STATE_COMPLETED,
    pb.TASK_STATE_FAILED,
    pb.TASK_STATE_CANCELED,
    pb.TASK_STATE_REJECTED,
)


def until_terminal(frame):
    return frame_state(frame) in TERMINAL


class Binding:
    name = "?"
    kind = "?"

    def __init__(self, report, tokens):
        self.report = report
        self.tokens = tokens

    def _method(self, rpc):
        return ref.SERVICE.methods_by_name[rpc]

    def _cls(self, rpc):
        return message_factory.GetMessageClass(self._method(rpc).output_type)

    def _record(self, rpc, vector, problems, count, what):
        self.report.problems(self.name, rpc, vector, problems, count, what)

    # unary -------------------------------------------------------------------

    def unary(self, rpc, request, vector, token="writer", version="1.1", record=True):
        ref.note_request_coverage(request, self.report.request_coverage)
        outcome, problems = self._unary(rpc, request, token, version)
        if record and outcome.error is None:
            self._record(rpc, vector, problems, 1, f"{self._method(rpc).output_type.name}")
        return outcome

    def expect(self, rpc, request, vector, **kw):
        """A unary call that must succeed; a refusal is recorded as a failure."""
        outcome = self.unary(rpc, request, vector, **kw)
        if outcome.error is not None:
            self.report.add(self.name, rpc, vector, "call", False, "refused: " + outcome.error.describe())
            return None
        return outcome.message

    # server streams ----------------------------------------------------------

    def stream(self, rpc, request, vector, stop=until_terminal, token="writer", version="1.1", wait=20, record=True):
        ref.note_request_coverage(request, self.report.request_coverage)
        result = self._stream(rpc, request, stop, token, version, wait)
        if record and (result.frames or result.error is None):
            self._record(rpc, vector, result.problems, len(result.frames), "StreamResponse frame(s)")
        return result


class TapChannel:
    """Hands the generated stub a channel whose deserialiser keeps the bytes."""

    def __init__(self, channel):
        self._channel = channel

    def _tap(self, kind):
        def build(method, request_serializer=None, response_deserializer=None, **kwargs):
            return getattr(self._channel, kind)(
                method,
                request_serializer=request_serializer,
                response_deserializer=lambda raw: raw,
                **kwargs,
            )

        return build

    def __getattr__(self, name):
        if name in ("unary_unary", "unary_stream", "stream_unary", "stream_stream"):
            return self._tap(name)
        return getattr(self._channel, name)


class GrpcBinding(Binding):
    kind = "grpc"

    def __init__(self, report, tokens, target):
        super().__init__(report, tokens)
        self.name = "grpc"
        self.channel = grpc.insecure_channel(target)
        self.stub = pb_grpc.A2AServiceStub(TapChannel(self.channel))

    def _metadata(self, token, version):
        metadata = []
        if version is not None:
            metadata.append(("a2a-version", version))
        if token is not None:
            metadata.append(("authorization", "Bearer " + self.tokens.get(token, token)))
        return metadata

    def _error(self, exc):
        problems, details = [], []
        try:
            status = rpc_status.from_call(exc)
        except Exception as err:
            status = None
            problems.append(f"grpc-status-details-bin does not agree with the status: {err}")
        if status is not None:
            details = list(status.details)
        return ErrorView("grpc", exc.code().name, exc.details(), details, problems=problems)

    def raw_call(self, path, body, token="writer", version="1.1"):
        """Sends `body` unchanged as the request message of `path`; returns the
        `ErrorView` of the refusal, or None when the call succeeded."""
        call = self.channel.unary_unary(path, request_serializer=lambda raw: raw, response_deserializer=lambda raw: raw)
        try:
            call(body, metadata=self._metadata(token, version), timeout=30)
        except grpc.RpcError as exc:
            return self._error(exc)
        return None

    def _unary(self, rpc, request, token, version):
        try:
            raw = getattr(self.stub, rpc)(request, metadata=self._metadata(token, version), timeout=30)
        except grpc.RpcError as exc:
            return Outcome(error=self._error(exc)), {}
        message, problems = check_pb(self.report, raw, self._cls(rpc))
        return Outcome(message=message, raw=raw), problems

    def _stream(self, rpc, request, stop, token, version, wait):
        result = StreamResult()
        call = getattr(self.stub, rpc)(request, metadata=self._metadata(token, version), timeout=wait)
        try:
            for raw in call:
                message, problems = check_pb(self.report, raw, pb.StreamResponse)
                merge(result.problems, problems, f"frame {len(result.frames)}: ")
                if message is None:
                    continue
                result.frames.append(message)
                if stop and stop(message):
                    # Per spec the server closes after a terminal frame; give
                    # it a moment to do so before we judge.
                    try:
                        extra = next(call)
                        result.notes.append(f"{len(extra)} more bytes after the stop frame")
                    except StopIteration:
                        result.closed = True
                    except grpc.RpcError as exc:
                        if exc.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
                            result.notes.append("stream still open after the stop frame")
                        else:
                            result.error = self._error(exc)
                    break
            else:
                result.closed = True
        except grpc.RpcError as exc:
            if exc.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
                result.notes.append(f"no stop frame within {wait}s")
            elif exc.code() != grpc.StatusCode.CANCELLED:
                result.error = self._error(exc)
        finally:
            call.cancel()
        return result

    def live(self, first, vector, token="writer", version="1.1"):
        return GrpcLive(self, first, vector, token, version)


class GrpcLive:
    duplex = True

    def __init__(self, binding, first, vector, token, version):
        self.binding = binding
        self.vector = vector
        self.uplink = queue.Queue()
        self.frames = []
        self.problems = {}
        self.error = None
        self.closed = False
        self._downlink = queue.Queue()
        self.send(first)
        self.call = binding.stub.SendLiveMessage(
            iter(self.uplink.get, None), metadata=binding._metadata(token, version), timeout=40
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for raw in self.call:
                message, problems = check_pb(self.binding.report, raw, pb.StreamResponse)
                merge(self.problems, problems, f"frame {len(self.frames)}: ")
                if message is not None:
                    self.frames.append(message)
                    self._downlink.put(message)
            self.closed = True
        except grpc.RpcError as exc:
            if exc.code() not in (grpc.StatusCode.CANCELLED, grpc.StatusCode.DEADLINE_EXCEEDED):
                self.error = self.binding._error(exc)
        finally:
            self._downlink.put(None)

    def send(self, request):
        """Native duplex: the uplink is the request stream; nothing is returned."""
        ref.note_request_coverage(request, self.binding.report.request_coverage)
        self.uplink.put(request)
        return None

    def next(self, timeout=10):
        try:
            return self._downlink.get(timeout=timeout)
        except queue.Empty:
            return None

    def half_close(self):
        self.uplink.put(None)

    def close(self):
        self.uplink.put(None)
        self.call.cancel()
        self.binding._record("SendLiveMessage", self.vector, self.problems, len(self.frames), "StreamResponse frame(s)")


class HttpBinding(Binding):
    """Shared by the HTTP+JSON and JSON-RPC bindings."""

    def _headers(self, token, version, body=False, extra=None):
        headers = {"accept": "application/json, text/event-stream"}
        if version is not None:
            headers["a2a-version"] = version
        if token is not None:
            headers["authorization"] = "Bearer " + self.tokens.get(token, token)
        if body:
            headers["content-type"] = self.request_content_type
        headers.update(extra or {})
        return headers

    def _parse(self, body):
        try:
            return ref.loads(body), None
        except Exception as exc:
            return None, f"body is not strict JSON: {exc}: {body[:160]!r}"

    def _stream(self, rpc, request, stop, token, version, wait):
        result = StreamResult()
        method, url, body = self._request(rpc, request)
        sse = SseStream(method, url, self._headers(token, version, body is not None), body, timeout=wait + 5)
        result.http = sse
        if sse.response is not None:
            outcome, _ = self._answer(rpc, sse.response, None)
            result.error = outcome.error
            if outcome.error is None:
                result.problems["strict"] = [
                    f"not an event stream: HTTP {sse.status} {sse.headers.get('content-type')}"
                ]
            return result
        deadline = time.monotonic() + wait
        while True:
            data = sse.next(max(0.1, deadline - time.monotonic()))
            if data is None:
                if sse.closed_by_server:
                    result.closed = True
                else:
                    result.notes.append(f"no stop frame within {wait}s")
                break
            stopped = self._frame(rpc, data, result, stop)
            if stopped:
                extra = sse.next(3)
                if extra is None and sse.closed_by_server:
                    result.closed = True
                elif extra is None:
                    result.notes.append("stream still open after the stop frame")
                else:
                    result.notes.append(f"another event after the stop frame: {extra[:120]}")
                break
        extra_fields = sse.fields - {"data", ":comment"}
        if extra_fields:
            result.notes.append(f"SSE fields besides data: {sorted(extra_fields)}")
        sse.close()
        return result

    def _frame(self, rpc, data, result, stop):
        value, err = self._parse(data.encode("utf-8"))
        index = len(result.frames)
        if err:
            merge(result.problems, {"strict": [err]}, f"frame {index}: ")
            return False
        payload, error, problems = self._unwrap_frame(value)
        merge(result.problems, problems, f"frame {index}: ")
        if error is not None:
            result.error = error
            return True
        if payload is None:
            return False
        message, problems = check_json(self.report, payload, pb.StreamResponse)
        merge(result.problems, problems, f"frame {index}: ")
        if message is None:
            return False
        result.frames.append(message)
        return bool(stop and stop(message))

    def live(self, first, vector, token="writer", version="1.1"):
        return HttpLive(self, first, vector, token, version)


class UplinkAnswer:
    def __init__(self, status, headers, bodies, still_open):
        self.status = status
        self.headers = headers
        self.bodies = bodies
        self.still_open = still_open

    def describe(self):
        shown = b" | ".join(self.bodies)[:200]
        return f"HTTP {self.status} {self.headers.get('content-type')}, {len(self.bodies)} body(ies){', left open' if self.still_open else ''}: {shown!r}"


class HttpLive:
    """`SendLiveMessage` over HTTP: the first call's response is the downlink;
    every later request is its own short call to the same operation (spec
    3.1.12)."""

    duplex = False

    def __init__(self, binding, first, vector, token, version):
        self.binding = binding
        self.vector = vector
        self.token = token
        self.version = version
        self.result = StreamResult()
        ref.note_request_coverage(first, binding.report.request_coverage)
        method, url, body = binding._request("SendLiveMessage", first)
        self.request_id = getattr(binding, "_last_id", None)
        self.sse = SseStream(method, url, binding._headers(token, version, True), body, timeout=40)
        self.error = None
        if self.sse.response is not None:
            outcome, _ = binding._answer("SendLiveMessage", self.sse.response, None)
            self.error = outcome.error

    @property
    def frames(self):
        return self.result.frames

    @property
    def closed(self):
        return self.sse.closed_by_server

    def next(self, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            data = self.sse.next(max(0.05, deadline - time.monotonic()))
            if data is None:
                return None
            before = len(self.result.frames)
            # Downlink frames answer the call that opened the stream, not
            # whichever uplink call was made last.
            self.binding._last_id = self.request_id
            self.binding._frame("SendLiveMessage", data, self.result, None)
            if self.result.error is not None and self.error is None:
                self.error = self.result.error
            if len(self.result.frames) > before:
                return self.result.frames[-1]
            if time.monotonic() > deadline:
                return None

    def send(self, request):
        """An uplink call: its own short-lived call to the same operation.

        Returns an `UplinkAnswer`. The server may answer with a JSON body or
        with an event stream; an event stream that stays open is read for two
        idle seconds and then dropped.
        """
        ref.note_request_coverage(request, self.binding.report.request_coverage)
        method, url, body = self.binding._request("SendLiveMessage", request)
        sse = SseStream(method, url, self.binding._headers(self.token, self.version, True), body, timeout=20)
        if sse.response is not None:
            return UplinkAnswer(sse.status, sse.headers, [sse.response.body], False)
        datas = []
        while True:
            data = sse.next(2)
            if data is None:
                break
            datas.append(data.encode("utf-8"))
        still_open = not sse.closed_by_server
        sse.close()
        return UplinkAnswer(sse.status, sse.headers, datas, still_open)

    def half_close(self):
        pass

    def close(self):
        self.sse.close()
        self.binding._record(
            "SendLiveMessage", self.vector, self.result.problems, len(self.result.frames), "StreamResponse frame(s)"
        )


HTTP_STATUS_NAMES = {
    400: ("INVALID_ARGUMENT", "FAILED_PRECONDITION", "OUT_OF_RANGE"),
    401: ("UNAUTHENTICATED",),
    403: ("PERMISSION_DENIED",),
    404: ("NOT_FOUND",),
    409: ("ABORTED", "ALREADY_EXISTS"),
    429: ("RESOURCE_EXHAUSTED",),
    499: ("CANCELLED",),
    500: ("INTERNAL", "UNKNOWN", "DATA_LOSS"),
    501: ("UNIMPLEMENTED",),
    503: ("UNAVAILABLE",),
    504: ("DEADLINE_EXCEEDED",),
}


class RestBinding(HttpBinding):
    kind = "rest"
    request_content_type = "application/a2a+json"

    def __init__(self, report, tokens, base_url):
        super().__init__(report, tokens)
        self.name = "http+json"
        self.base_url = base_url.rstrip("/")

    def _request(self, rpc, request):
        verb, template, body_rule = ref.http_rule(self._method(rpc))
        as_json = json_format.MessageToDict(request)
        by_proto_name = {f.name: f.json_name for f in request.DESCRIPTOR.fields}

        def fill(match):
            name = match.group(1)
            as_json.pop(by_proto_name[name], None)
            return urllib.parse.quote(str(getattr(request, name)), safe="")

        path = re.sub(r"\{(\w+)(?:=\*)?\}", fill, template)
        if body_rule == "*":
            return verb, self.base_url + path, json.dumps(as_json).encode("utf-8")
        query = []
        for key, value in as_json.items():
            for item in value if isinstance(value, list) else [value]:
                if isinstance(item, bool):
                    item = "true" if item else "false"
                elif isinstance(item, (dict, list)):
                    raise ValueError(f"{rpc}.{key} cannot travel as a query parameter (spec 11.5)")
                query.append((key, str(item)))
        url = self.base_url + path + ("?" + urllib.parse.urlencode(query) if query else "")
        return verb, url, None

    def _unary(self, rpc, request, token, version):
        method, url, body = self._request(rpc, request)
        resp = http_call(method, url, self._headers(token, version, body is not None), body)
        return self._answer(rpc, resp, None)

    def _answer(self, rpc, resp, _request_id):
        if resp.status >= 400:
            return Outcome(error=self._error(resp), http=resp), {}
        cls = self._cls(rpc)
        if resp.status == 204 and not resp.body and cls.DESCRIPTOR.full_name == "google.protobuf.Empty":
            # Spec 3.1.10: the confirmation of a delete is implementation
            # specific; 204 with no body is the HTTP spelling of Empty.
            return Outcome(message=cls(), http=resp, raw=resp.body), {}
        value, err = self._parse(resp.body)
        if err:
            return Outcome(message=None, http=resp, raw=resp.body), {"strict": [err]}
        note_raw_canonical(self.report, resp.body, value)
        message, problems = check_json(self.report, value, cls)
        return Outcome(message=message, http=resp, raw=resp.body), problems

    def _error(self, resp):
        """Spec 11.6: `{"error": {code, status, message, details[]}}`."""
        problems = []
        value, err = self._parse(resp.body)
        if err:
            return ErrorView("http+json", resp.status, "", [], resp.status, problems=[err], raw=resp.body)
        error = value.get("error") if isinstance(value, dict) else None
        if not isinstance(error, dict) or set(value) != {"error"}:
            return ErrorView(
                "http+json", resp.status, "", [], resp.status,
                problems=[f"body is not {{\"error\": {{...}}}}: {resp.body[:200]!r}"], raw=resp.body,
            )
        extra = set(error) - {"code", "status", "message", "details"}
        if extra:
            problems.append(f"error object has members the spec does not define: {sorted(extra)}")
        if error.get("code") != resp.status or isinstance(error.get("code"), bool):
            problems.append(f"error.code is {error.get('code')!r}, the HTTP status is {resp.status}")
        if not isinstance(error.get("message"), str) or not error.get("message"):
            problems.append("error.message is not a non-empty string")
        details = _details_from_json(error.get("details"), problems)
        return ErrorView(
            "http+json", resp.status, error.get("message"), details, resp.status,
            status_name=error.get("status"), problems=problems, raw=resp.body,
        )

    def _unwrap_frame(self, value):
        # `{"error": ...}` is either the HTTP error envelope (11.6, integer
        # `code`) or a StreamResponse carrying a StreamError (string `code`).
        inner = value.get("error") if isinstance(value, dict) else None
        if isinstance(inner, dict) and set(value) == {"error"} and not isinstance(inner.get("code"), str):
            fake = HttpResponse(value["error"].get("code", 0), {}, json.dumps(value).encode("utf-8"))
            error = self._error(fake)
            error.http_status = None
            return None, error, {}
        return value, None, {}


class JsonRpcBinding(HttpBinding):
    kind = "jsonrpc"
    request_content_type = "application/json"

    def __init__(self, report, tokens, url, name):
        super().__init__(report, tokens)
        self.name = name
        self.url = url
        self._ids = iter(range(1, 10**9))
        self._last_id = None

    def _request(self, rpc, request):
        self._last_id = next(self._ids)
        envelope = {
            "jsonrpc": "2.0",
            "id": self._last_id,
            "method": rpc,
            "params": json_format.MessageToDict(request),
        }
        return "POST", self.url, json.dumps(envelope).encode("utf-8")

    def _unary(self, rpc, request, token, version):
        method, url, body = self._request(rpc, request)
        resp = http_call(method, url, self._headers(token, version, True), body)
        return self._answer(rpc, resp, self._last_id)

    def _envelope(self, value, request_id):
        """JSON-RPC 2.0 response object: exactly jsonrpc, id and result|error."""
        problems = []
        if not isinstance(value, dict):
            return [f"response is {type(value).__name__}, not an object"]
        if value.get("jsonrpc") != "2.0":
            problems.append(f"jsonrpc is {value.get('jsonrpc')!r}")
        members = set(value) - {"jsonrpc", "id"}
        if members not in ({"result"}, {"error"}):
            problems.append(f"members besides jsonrpc and id: {sorted(members)}")
        if "id" not in value:
            problems.append("no id member")
        elif request_id is not None and (value["id"] != request_id or type(value["id"]) is not type(request_id)):
            problems.append(f"id is {value['id']!r}, the request sent {request_id!r}")
        return problems

    def _answer(self, rpc, resp, request_id):
        value, err = self._parse(resp.body)
        if err:
            if resp.status >= 400:
                return Outcome(error=ErrorView(self.name, None, "", [], resp.status, problems=[err], raw=resp.body), http=resp), {}
            return Outcome(http=resp, raw=resp.body), {"strict": [err]}
        problems = {}
        # Credentials are refused before the body is read, so the request id
        # is unknown: JSON-RPC 2.0 says `id` is null then.
        if resp.status in (401, 403) and isinstance(value, dict) and value.get("id") is None:
            request_id = None
        envelope = self._envelope(value, request_id)
        if isinstance(value, dict) and "error" in value:
            return Outcome(error=self._error(value["error"], resp.status, envelope, resp.body), http=resp), {}
        if envelope:
            problems["strict"] = ["JSON-RPC envelope: " + item for item in envelope]
        if not isinstance(value, dict) or "result" not in value:
            if resp.status >= 400:
                return Outcome(
                    error=ErrorView(self.name, None, "", [], resp.status, problems=["no JSON-RPC error object"], raw=resp.body),
                    http=resp,
                ), {}
            return Outcome(http=resp, raw=resp.body), problems
        note_raw_canonical(self.report, resp.body, value)
        message, found = check_json(self.report, value["result"], self._cls(rpc))
        merge(problems, found)
        return Outcome(message=message, http=resp, raw=resp.body), problems

    def _error(self, error, http_status, envelope_problems, raw=None):
        """Spec 9.5: `error.code`, `error.message`, `error.data` (array of Any)."""
        problems = ["JSON-RPC envelope: " + item for item in envelope_problems]
        if not isinstance(error, dict):
            return ErrorView(self.name, None, "", [], http_status, problems=problems + ["error is not an object"], raw=raw)
        extra = set(error) - {"code", "message", "data"}
        if extra:
            problems.append(f"error object has members JSON-RPC 2.0 does not define: {sorted(extra)}")
        if not isinstance(error.get("code"), int) or isinstance(error.get("code"), bool):
            problems.append(f"error.code is {error.get('code')!r}, not an integer")
        if not isinstance(error.get("message"), str) or not error.get("message"):
            problems.append("error.message is not a non-empty string")
        details = _details_from_json(error.get("data"), problems)
        return ErrorView(self.name, error.get("code"), error.get("message"), details, http_status, problems=problems, raw=raw)

    def _unwrap_frame(self, value):
        envelope = self._envelope(value, self._last_id)
        if isinstance(value, dict) and "error" in value:
            return None, self._error(value["error"], None, envelope), {}
        problems = {"strict": ["JSON-RPC envelope: " + item for item in envelope]} if envelope else {}
        if not isinstance(value, dict) or "result" not in value:
            return None, None, problems
        return value["result"], None, problems

    def raw_call(self, body, token="writer", version="1.1"):
        """Posts arbitrary bytes, for the JSON-RPC protocol-level error paths."""
        resp = http_call("POST", self.url, self._headers(token, version, True), body)
        value, err = self._parse(resp.body)
        if err or not isinstance(value, dict) or "error" not in value:
            return ErrorView(self.name, None, "", [], resp.status, problems=[err or f"no error member: {resp.body[:160]!r}"], raw=resp.body)
        return self._error(value["error"], resp.status, self._envelope(value, None), resp.body)
