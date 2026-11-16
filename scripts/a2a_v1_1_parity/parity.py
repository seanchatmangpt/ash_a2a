#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""A2A v1.1 byte-for-byte parity of a running ash_a2a simulation server
against the upstream reference. See README.md next to this file.

    parity.py --http http://127.0.0.1:PORT --grpc 127.0.0.1:PORT [--report FILE] [--json]

Exit status: 0 when no row fails, 1 when any row fails, 2 when the reference
stubs are missing.
"""

import argparse
import http.server
import json
import sys
import threading
import time
import uuid

from google.protobuf import json_format

sys.dont_write_bytecode = True

import harness as h  # noqa: E402
import reference as ref  # noqa: E402
from reference import pb  # noqa: E402

SPEC = "a2a v1.1.0-rc docs/specification.md"
DOMAIN = "a2a-protocol.org"

# What the spec states for each A2A error, per binding (section 5.4), and the
# ErrorInfo reason (sections 9.5, 10.6, 11.6: the error type in
# UPPER_SNAKE_CASE without the "Error" suffix).
A2A_ERRORS = {
    "TaskNotFoundError": (-32001, "NOT_FOUND", 404, "TASK_NOT_FOUND"),
    "TaskNotCancelableError": (-32002, "FAILED_PRECONDITION", 400, "TASK_NOT_CANCELABLE"),
    "PushNotificationNotSupportedError": (-32003, "FAILED_PRECONDITION", 400, "PUSH_NOTIFICATION_NOT_SUPPORTED"),
    "UnsupportedOperationError": (-32004, "FAILED_PRECONDITION", 400, "UNSUPPORTED_OPERATION"),
    "ContentTypeNotSupportedError": (-32005, "INVALID_ARGUMENT", 400, "CONTENT_TYPE_NOT_SUPPORTED"),
    "InvalidAgentResponseError": (-32006, "INTERNAL", 500, "INVALID_AGENT_RESPONSE"),
    "ExtendedAgentCardNotConfiguredError": (-32007, "FAILED_PRECONDITION", 400, "EXTENDED_AGENT_CARD_NOT_CONFIGURED"),
    "ExtensionSupportRequiredError": (-32008, "FAILED_PRECONDITION", 400, "EXTENSION_SUPPORT_REQUIRED"),
    "VersionNotSupportedError": (-32009, "FAILED_PRECONDITION", 400, "VERSION_NOT_SUPPORTED"),
    "TaskGenerationMismatchError": (-32010, "ABORTED", 409, "TASK_GENERATION_MISMATCH"),
}

# Errors the spec does not give an A2A type: section 3.3.2 names the code of
# each category per binding. (JSON-RPC code, gRPC status, HTTP status.)
GENERIC_ERRORS = {
    "validation": (-32602, "INVALID_ARGUMENT", 400),
    "authentication": (None, "UNAUTHENTICATED", 401),
    "authorization": (None, "PERMISSION_DENIED", 403),
}

# Response-side fields no vector can make the simulation server emit, with
# the reason. A field missing from the observed set and from this table fails
# the run, so the list cannot rot silently.
UNREACHABLE = {
    "TaskPushNotificationConfig.tenant": "the simulation server is single-tenant; no route carries a tenant",
    "AgentInterface.tenant": "single-tenant: the card declares no tenant",
    "AgentCard.provider": "AshA2A.Sim.Agent declares no provider",
    "AgentProvider.url": "AshA2A.Sim.Agent declares no provider",
    "AgentProvider.organization": "AshA2A.Sim.Agent declares no provider",
    "AgentCard.documentation_url": "AshA2A.Sim.Agent declares no documentation URL",
    "AgentCard.icon_url": "AshA2A.Sim.Agent declares no icon",
    "AgentCard.signatures": "the simulation server does not sign its card",
    "AgentCardSignature.protected": "the simulation server does not sign its card",
    "AgentCardSignature.signature": "the simulation server does not sign its card",
    "AgentCardSignature.header": "the simulation server does not sign its card",
    "AgentCapabilities.extensions": "AshA2A.Sim.Agent declares no extension",
    "AgentExtension.uri": "AshA2A.Sim.Agent declares no extension",
    "AgentExtension.description": "AshA2A.Sim.Agent declares no extension",
    "AgentExtension.required": "AshA2A.Sim.Agent declares no extension",
    "AgentExtension.params": "AshA2A.Sim.Agent declares no extension",
    "AgentSkill.examples": "the Sim skills declare no examples",
    "AgentSkill.input_modes": "the Sim skills declare no per-skill modes",
    "AgentSkill.output_modes": "the Sim skills declare no per-skill modes",
    "AgentSkill.security_requirements": "the Sim skills declare no per-skill security",
    "SecurityScheme.api_key_security_scheme": "the Sim agent declares one scheme: HTTP bearer",
    "SecurityScheme.oauth2_security_scheme": "the Sim agent declares one scheme: HTTP bearer",
    "SecurityScheme.open_id_connect_security_scheme": "the Sim agent declares one scheme: HTTP bearer",
    "SecurityScheme.mtls_security_scheme": "the Sim agent declares one scheme: HTTP bearer",
    "HTTPAuthSecurityScheme.description": "the bearer scheme carries no description",
    "HTTPAuthSecurityScheme.bearer_format": "the bearer scheme declares no format",
    "ListTaskPushNotificationConfigsResponse.next_page_token": "the server returns every config of a task in one page",
    "SendMessageResponse.message": "every Sim skill answers with a Task, never a bare Message",
    "StreamResponse.message": "every Sim skill answers with a Task, never a bare Message",
    "TaskStatusUpdateEvent.metadata": "the Sim skills attach no event metadata",
    "TaskArtifactUpdateEvent.metadata": "the Sim skills attach no event metadata",
    "TaskMessageUpdateEvent.metadata": "the Sim skills attach no event metadata",
    "StreamError.metadata": "the server attaches no metadata to a stream rejection",
    "Artifact.extensions": "AshA2A.Sim.Agent declares no extension",
    "Artifact.description": "the Sim skills do not describe their artifacts",
}
for _name in (
    "APIKeySecurityScheme", "OAuth2SecurityScheme", "OpenIdConnectSecurityScheme", "MutualTlsSecurityScheme",
    "OAuthFlows", "AuthorizationCodeOAuthFlow", "ClientCredentialsOAuthFlow", "ImplicitOAuthFlow",
    "PasswordOAuthFlow", "DeviceCodeOAuthFlow",
):
    for _field in pb.DESCRIPTOR.message_types_by_name[_name].fields:
        UNREACHABLE[f"{_name}.{_field.name}"] = "the Sim agent declares one scheme: HTTP bearer"

# Request-side fields the script does not send, with the reason.
UNSENT = {
    "tenant": "the simulation server is single-tenant (no /{tenant}/ route is mounted)",
}

NORMALISATIONS = [
    {
        "what": "JSON object member order and insignificant whitespace",
        "how": "both sides are written as RFC 8785 (JCS) before the byte comparison",
        "why": "JSON objects are unordered (RFC 8259 section 4); ProtoJSON fixes no member order",
    },
    {
        "what": "number spelling",
        "how": "RFC 8785 / ECMAScript number form on both sides (1.0 and 1 are the same number)",
        "why": "only applies to google.protobuf.Value doubles; 64-bit integer fields are strings in ProtoJSON and are compared as strings",
    },
    {
        "what": "REQUIRED fields at their zero value",
        "how": "the reference emits a field the upstream proto marks REQUIRED even when it holds the zero value",
        "why": "spec 5.7: a REQUIRED field MUST be present; the spec's own ListTasks example (6.5) carries \"nextPageToken\": \"\". Every other default-valued field must be omitted, as the reference encoder does",
    },
    {
        "what": "JSON-RPC envelope",
        "how": "the `result` member is compared; `jsonrpc`, `id` and the member set are checked separately and exactly",
        "why": "the envelope is JSON-RPC 2.0, not a protobuf message",
    },
    {
        "what": "HTTP+JSON error envelope",
        "how": "`error.code`, `error.status`, `error.message` are checked field by field; each `details[]` entry is parsed as google.protobuf.Any and compared canonically with its re-emission",
        "why": "spec 11.6 adds `status` to google.rpc.Status, so the object is not a protobuf message the reference can round-trip whole",
    },
    {
        "what": "HTTP 204 for DeleteTaskPushNotificationConfig",
        "how": "an empty 204 body is accepted as google.protobuf.Empty",
        "why": "spec 3.1.10: the confirmation of deletion is implementation-specific",
    },
]

NOT_NORMALISED = (
    "enum spelling, field naming (camelCase), int64-as-string, timestamp format, "
    "default-value emission, null members, unknown or extra members, duplicate members, "
    "protobuf field order, map entry order and unknown protobuf fields are all compared as sent"
)


# -- request builders ----------------------------------------------------------


def uid(prefix="m"):
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def message(skill, data=None, task_id=None, context_id=None, extra=None):
    body = {
        "messageId": uid(),
        "role": "ROLE_USER",
        "parts": [{"data": data if data is not None else {}}],
        "metadata": {"skill": skill},
    }
    if task_id:
        body["taskId"] = task_id
    if context_id:
        body["contextId"] = context_id
    body.update(extra or {})
    return json_format.ParseDict(body, pb.Message())


def send_request(skill, data=None, configuration=None, **kw):
    request = pb.SendMessageRequest(message=message(skill, data, **kw))
    if configuration:
        json_format.ParseDict(configuration, request.configuration)
    return request


class Env:
    def __init__(self, report, bindings, args, webhook):
        self.report = report
        self.bindings = bindings
        self.args = args
        self.webhook = webhook


def sem(b, operation, vector, ok, detail, check="semantics"):
    return b.report.add(b.name, operation, vector, check, bool(ok), detail)


def state_name(value):
    return pb.TaskState.Name(value)


def send(b, vector, skill, data=None, configuration=None, token="writer", **kw):
    reply = b.expect("SendMessage", send_request(skill, data, configuration, **kw), vector, token=token)
    if reply is None:
        return None
    if reply.WhichOneof("payload") != "task":
        sem(b, "SendMessage", vector, False, f"payload is {reply.WhichOneof('payload')}, not task")
        return None
    return reply.task


def get(b, vector, task_id, **fields):
    return b.expect("GetTask", pb.GetTaskRequest(id=task_id, **fields), vector)


def await_state(b, task_id, states, timeout=10):
    deadline = time.monotonic() + timeout
    task = None
    while time.monotonic() < deadline:
        outcome = b.unary("GetTask", pb.GetTaskRequest(id=task_id), "poll", record=False)
        task = outcome.message
        if task is not None and task.status.state in states:
            return task
        time.sleep(0.05)
    return task


# -- v1.1 task invariants (spec 3.2.7, 3.2.8) -----------------------------------


def task_invariants(task):
    """Problems with generation and timeline in one Task, per spec 3.2.7/3.2.8."""
    problems = []
    if task.generation < 1:
        problems.append(f"generation is {task.generation}; a v1.1 server always answers >= 1 (3.2.7)")
    last = 0
    for index, entry in enumerate(task.timeline):
        if entry.WhichOneof("entry") is None:
            problems.append(f"timeline[{index}] carries neither message nor status")
        if entry.generation <= last:
            problems.append(f"timeline[{index}].generation {entry.generation} does not follow {last} (3.2.8)")
        if entry.generation > task.generation:
            problems.append(f"timeline[{index}].generation {entry.generation} exceeds the task's {task.generation}")
        last = entry.generation
    for index, artifact in enumerate(task.artifacts):
        if artifact.start_generation < 1 or artifact.start_generation > task.generation:
            problems.append(f"artifacts[{index}].startGeneration is {artifact.start_generation}")
        if artifact.end_generation and artifact.end_generation < artifact.start_generation:
            problems.append(f"artifacts[{index}].endGeneration precedes startGeneration")
    return problems


def stream_invariants(result, first="task", require_terminal=True):
    """Ordering per spec 3.1.2 / 3.2.7 / 11.7: first frame, strictly increasing
    generation with no repeat, terminal status last, stream closed after it."""
    problems = []
    kinds = result.kinds()
    if not kinds:
        return ["no frame"]
    if first and kinds[0] != first:
        problems.append(f"first frame is {kinds[0]}, the spec says {first}")
    if first != "task" and "task" in kinds[:1]:
        problems.append("opened with a Task snapshot")
    problems += generation_problems(result.frames)
    if require_terminal:
        if h.frame_state(result.frames[-1]) not in h.TERMINAL:
            problems.append(f"last frame is {kinds[-1]}, not a terminal status")
        if not result.closed:
            problems.append("the server did not close the stream after the terminal frame: " + "; ".join(result.notes))
    return problems


# -- webhook receiver (push notification payloads, spec 4.3.3) ------------------


class Webhook:
    def __init__(self):
        self.deliveries = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                body = self.rfile.read(length)
                outer.deliveries.append(
                    {"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}
                )
                self.send_response(200)
                self.send_header("content-length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, tag):
        return f"http://127.0.0.1:{self.server.server_address[1]}/hook/{tag}"

    def wait(self, tag, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = [d for d in self.deliveries if d["path"].endswith("/" + tag)]
            if any(predicate(d) for d in found):
                return found
            time.sleep(0.05)
        return [d for d in self.deliveries if d["path"].endswith("/" + tag)]


# -- the vectors, run once per binding -------------------------------------------


def run_send(b, env):
    op = "SendMessage"

    task = send(b, "blocking send completes", "count_notes")
    if task is not None:
        problems = task_invariants(task)
        if task.status.state != pb.TASK_STATE_COMPLETED:
            problems.append(f"state is {state_name(task.status.state)}")
        if not task.artifacts:
            problems.append("no artifact (3.2.2: a blocking answer carries all artifacts)")
        if not task.timeline:
            problems.append("no timeline (3.2.8)")
        elif task.timeline[-1].WhichOneof("entry") != "status" or task.timeline[-1].status != task.status:
            problems.append("the last timeline entry is not the task's current status")
        sem(b, op, "blocking send completes", not problems, "; ".join(problems) or
            f"generation {task.generation}, {len(task.timeline)} timeline entries, {len(task.artifacts)} artifact(s)")

    # Every Part kind and every Message field a client can set.
    first_id = task.id if task is not None else None
    context = uid("ctx")
    rich = pb.SendMessageRequest(
        message=json_format.ParseDict(
            {
                "messageId": uid(),
                "contextId": context,
                "role": "ROLE_USER",
                "parts": [
                    {"data": {"stream": False, "n": 1.5, "big": 9007199254740991, "nested": {"a": [1, None, "x", True]}},
                     "metadata": {"k": "v"}},
                    {"text": "café ☃ \U0001F600 \"quoted\" \\ /", "mediaType": "text/plain"},
                    {"raw": "AAEC/v8=", "filename": "blob.bin", "mediaType": "text/plain"},
                    {"url": "https://example.com/a%20b?q=1", "filename": "a b.txt", "mediaType": "text/plain"},
                ],
                "metadata": {"skill": "list_notes", "trace": {"depth": 2}},
                "extensions": ["https://example.com/ext/v1"],
                "referenceTaskIds": [first_id] if first_id else [],
            },
            pb.Message(),
        ),
    )
    rich.metadata.update({"requestTag": "parity"})
    rich.configuration.accepted_output_modes.extend(["text/plain"])
    reply = b.expect(op, rich, "every Part kind and Message field echoed")
    if reply is not None and reply.WhichOneof("payload") == "task":
        task = reply.task
        echoed = [e.message for e in task.timeline if e.WhichOneof("entry") == "message"]
        problems = []
        if task.context_id != context:
            problems.append(f"contextId is {task.context_id!r}, the client sent {context!r}")
        if not echoed:
            problems.append("the client message is not in the timeline (3.2.8)")
        else:
            sent = pb.Message()
            sent.CopyFrom(rich.message)
            got = pb.Message()
            got.CopyFrom(echoed[0])
            # The server may stamp the task and context it resolved.
            got.task_id, got.context_id = sent.task_id, sent.context_id
            if got != sent:
                problems.append(
                    "the echoed client message differs from the one sent: "
                    + str(ref.diff(json_format.MessageToDict(got), json_format.MessageToDict(sent)))
                )
        sem(b, op, "every Part kind and Message field echoed", not problems,
            "; ".join(problems) or "timeline message equals the sent message field for field")
        env.rich = getattr(env, "rich", {})
        env.rich[b.name] = task

    task = send(b, "returnImmediately answers a running task", "slow_count", {"delay_ms": 30000},
                {"returnImmediately": True})
    if task is not None:
        ok = task.status.state in (pb.TASK_STATE_SUBMITTED, pb.TASK_STATE_WORKING)
        sem(b, op, "returnImmediately answers a running task", ok, state_name(task.status.state))
        canceled = b.expect("CancelTask", pb.CancelTaskRequest(id=task.id), "cancel a running task")
        if canceled is not None:
            problems = task_invariants(canceled)
            if canceled.status.state != pb.TASK_STATE_CANCELED:
                problems.append(f"state is {state_name(canceled.status.state)}")
            sem(b, "CancelTask", "cancel a running task", not problems, "; ".join(problems) or "TASK_STATE_CANCELED")
        # 3.3.1: cancel is idempotent. 3.1.5 also lets a server answer
        # TaskNotCancelableError for a task that is already canceled.
        request = pb.CancelTaskRequest(id=task.id)
        request.metadata.update({"reason": "parity"})
        vector = "cancel again, with metadata"
        outcome = b.unary("CancelTask", request, vector)
        if outcome.error is None:
            ok = outcome.message is not None and outcome.message.status.state == pb.TASK_STATE_CANCELED
            sem(b, "CancelTask", vector, ok, "idempotent: the canceled Task again (3.3.1)")
        else:
            expect_a2a_error(b, "CancelTask", vector, outcome, "TaskNotCancelableError", "3.1.5")

    task = send(b, "input-required interrupts", "create_note", {"body": "no title"})
    if task is not None:
        problems = task_invariants(task)
        if task.status.state != pb.TASK_STATE_INPUT_REQUIRED:
            problems.append(f"state is {state_name(task.status.state)}")
        sem(b, op, "input-required interrupts", not problems, "; ".join(problems) or
            f"TASK_STATE_INPUT_REQUIRED at generation {task.generation}")
        follow = send(b, "follow-up with matching ifGenerationMatch", "create_note",
                      {"title": uid("note"), "body": "b"},
                      {"ifGenerationMatch": str(task.generation)}, task_id=task.id, context_id=task.context_id)
        if follow is not None:
            problems = task_invariants(follow)
            if follow.id != task.id:
                problems.append("the follow-up created another task")
            if follow.status.state != pb.TASK_STATE_COMPLETED:
                problems.append(f"state is {state_name(follow.status.state)}")
            if follow.generation <= task.generation:
                problems.append(f"generation did not advance ({task.generation} -> {follow.generation})")
            messages = [e for e in follow.timeline if e.WhichOneof("entry") == "message"]
            if len(messages) < 2:
                problems.append(f"{len(messages)} client message(s) in the timeline, two were sent")
            sem(b, op, "follow-up with matching ifGenerationMatch", not problems, "; ".join(problems) or
                f"generation {task.generation} -> {follow.generation}, {len(messages)} client messages in the timeline")

    task = send(b, "auth-required interrupts", "step_up")
    if task is not None:
        ok = task.status.state == pb.TASK_STATE_AUTH_REQUIRED and len(task.status.message.parts) > 0
        sem(b, op, "auth-required interrupts", ok,
            f"{state_name(task.status.state)} with {len(task.status.message.parts)} status message part(s)")
        follow = send(b, "auth-required resumes", "step_up", {"otp": "123456"}, task_id=task.id, context_id=task.context_id)
        if follow is not None:
            sem(b, op, "auth-required resumes", follow.status.state == pb.TASK_STATE_COMPLETED,
                state_name(follow.status.state))

    task = send(b, "unclassified skill is refused", "unclassified_note")
    if task is not None:
        ok = task.status.state in (pb.TASK_STATE_REJECTED, pb.TASK_STATE_FAILED)
        sem(b, op, "unclassified skill is refused", ok, state_name(task.status.state))

    task = send(b, "authority refusal fails the task", "create_note", {"title": uid("t")}, token="reader")
    if task is not None:
        ok = task.status.state in (pb.TASK_STATE_REJECTED, pb.TASK_STATE_FAILED)
        sem(b, op, "authority refusal fails the task", ok, state_name(task.status.state))

    for length, vector in ((0, "timelineLength 0 and historyLength 0 omit both"), (1, "timelineLength 1 and historyLength 1")):
        task = send(b, vector, "count_notes", None, {"timelineLength": length, "historyLength": length})
        if task is not None:
            ok = len(task.timeline) == length and len(task.history) == length
            sem(b, op, vector, ok, f"{len(task.timeline)} timeline entries, {len(task.history)} history messages (3.2.4)")


def run_get_list(b, env):
    context = uid("ctx")
    tasks = [send(b, "seed for GetTask/ListTasks", "count_notes", context_id=context) for _ in range(3)]
    tasks = [t for t in tasks if t is not None]
    if len(tasks) < 3:
        return
    first = tasks[0]

    got = get(b, "by id", first.id)
    if got is not None:
        sem(b, "GetTask", "by id", got == first,
            "GetTask answers the Task SendMessage answered" if got == first else
            str(ref.diff(json_format.MessageToDict(got), json_format.MessageToDict(first))))
    got = get(b, "timelineLength 1", first.id, timeline_length=1)
    if got is not None:
        ok = len(got.timeline) == 1 and got.timeline[0] == first.timeline[-1]
        sem(b, "GetTask", "timelineLength 1", ok, f"{len(got.timeline)} entry, the most recent one: {ok}")
    got = get(b, "historyLength 0 and timelineLength 0", first.id, history_length=0, timeline_length=0)
    if got is not None:
        sem(b, "GetTask", "historyLength 0 and timelineLength 0", not got.history and not got.timeline,
            f"{len(got.history)} history, {len(got.timeline)} timeline")
    got = get(b, "currentGeneration behind answers at once", first.id, current_generation=first.generation - 1)
    if got is not None:
        sem(b, "GetTask", "currentGeneration behind answers at once", got.generation == first.generation,
            f"generation {got.generation} (3.2.7 long-polling)")

    slow = send(b, "seed for long-poll", "slow_count", {"delay_ms": 700}, {"returnImmediately": True})
    if slow is not None:
        started = time.monotonic()
        got = get(b, "currentGeneration long-poll", slow.id, current_generation=slow.generation)
        if got is not None:
            took = time.monotonic() - started
            sem(b, "GetTask", "currentGeneration long-poll", got.generation > slow.generation,
                f"held {took:.2f}s, generation {slow.generation} -> {got.generation} (3.2.7)")
        await_state(b, slow.id, h.TERMINAL)

    op = "ListTasks"
    page = b.expect(op, pb.ListTasksRequest(context_id=context, page_size=2), "contextId filter, pageSize 2")
    if page is not None:
        problems = []
        if len(page.tasks) != 2:
            problems.append(f"{len(page.tasks)} tasks on a page of 2")
        if page.total_size != 3:
            problems.append(f"totalSize {page.total_size}, 3 tasks share the context")
        if page.page_size != 2:
            problems.append(f"pageSize {page.page_size}")
        if not page.next_page_token:
            problems.append("no nextPageToken although a page remains")
        if any(t.artifacts for t in page.tasks):
            problems.append("artifacts present although includeArtifacts was not set (proto: defaults to false)")
        sem(b, op, "contextId filter, pageSize 2", not problems, "; ".join(problems) or "2 of 3, token for the rest")
        rest = b.expect(op, pb.ListTasksRequest(context_id=context, page_size=2, page_token=page.next_page_token),
                        "pageToken, last page")
        if rest is not None:
            ids = {t.id for t in page.tasks} | {t.id for t in rest.tasks}
            ok = len(rest.tasks) == 1 and rest.next_page_token == "" and ids == {t.id for t in tasks}
            sem(b, op, "pageToken, last page", ok,
                f"{len(rest.tasks)} task, nextPageToken {rest.next_page_token!r}, union covers the context: {ids == {t.id for t in tasks}}")

    full = b.expect(op, pb.ListTasksRequest(context_id=context, include_artifacts=True, timeline_length=1, history_length=1),
                    "includeArtifacts, timelineLength 1, historyLength 1")
    if full is not None:
        ok = all(t.artifacts and len(t.timeline) == 1 and len(t.history) == 1 for t in full.tasks) and len(full.tasks) == 3
        sem(b, op, "includeArtifacts, timelineLength 1, historyLength 1", ok,
            f"{len(full.tasks)} tasks, artifacts {[len(t.artifacts) for t in full.tasks]}, "
            f"timeline {[len(t.timeline) for t in full.tasks]}, history {[len(t.history) for t in full.tasks]}")

    by_state = b.expect(op, pb.ListTasksRequest(context_id=context, status=pb.TASK_STATE_COMPLETED), "status filter")
    if by_state is not None:
        ok = len(by_state.tasks) == 3 and all(t.status.state == pb.TASK_STATE_COMPLETED for t in by_state.tasks)
        sem(b, op, "status filter", ok, f"{len(by_state.tasks)} completed tasks in the context")
    none = b.expect(op, pb.ListTasksRequest(context_id=context, status=pb.TASK_STATE_CANCELED), "status filter matching nothing")
    if none is not None:
        sem(b, op, "status filter matching nothing", len(none.tasks) == 0 and none.total_size == 0,
            f"{len(none.tasks)} tasks, totalSize {none.total_size}")

    request = pb.ListTasksRequest(context_id=context)
    request.status_timestamp_after.FromSeconds(4102444800)  # 2100-01-01
    later = b.expect(op, request, "statusTimestampAfter in the future")
    if later is not None:
        sem(b, op, "statusTimestampAfter in the future", len(later.tasks) == 0, f"{len(later.tasks)} tasks")
    request = pb.ListTasksRequest(context_id=context)
    request.status_timestamp_after.FromSeconds(946684800)  # 2000-01-01
    earlier = b.expect(op, request, "statusTimestampAfter in the past")
    if earlier is not None:
        sem(b, op, "statusTimestampAfter in the past", len(earlier.tasks) == 3, f"{len(earlier.tasks)} tasks")


def run_streams(b, env):
    op = "SendStreamingMessage"
    send(b, "seed a note to stream", "create_note", {"title": uid("stream"), "body": "x"})
    result = b.stream(op, send_request("list_notes", {"stream": True}), "task, artifact chunks, terminal status")
    problems = stream_invariants(result)
    if "artifact_update" not in result.kinds():
        problems.append("no artifactUpdate frame")
    if result.error is not None:
        problems.append("stream error: " + result.error.describe())
    sem(b, op, "task, artifact chunks, terminal status", not problems, "; ".join(problems) or
        f"{len(result.frames)} frames: {' '.join(result.kinds())}")
    if result.frames and result.frames[0].WhichOneof("payload") == "task":
        task_id = result.frames[0].task.id
        final = await_state(b, task_id, h.TERMINAL)
        if final is not None:
            last = h.frame_generation(result.frames[-1])
            artifact_ids = {f.artifact_update.artifact.artifact_id for f in result.frames if f.WhichOneof("payload") == "artifact_update"}
            ok = final.generation == last and artifact_ids <= {a.artifact_id for a in final.artifacts}
            sem(b, op, "stream generation agrees with GetTask", ok,
                f"last frame generation {last}, GetTask generation {final.generation}; streamed artifacts stored: "
                f"{artifact_ids <= {a.artifact_id for a in final.artifacts}} (3.2.7: one event per mutation)")

    result = b.stream(op, send_request("create_note", {"body": "no title"}),
                      "interrupted stream stays valid", stop=lambda f: h.frame_state(f) == pb.TASK_STATE_INPUT_REQUIRED, wait=10)
    problems = stream_invariants(result, require_terminal=False)
    if not result.frames or h.frame_state(result.frames[-1]) != pb.TASK_STATE_INPUT_REQUIRED:
        problems.append("no TASK_STATE_INPUT_REQUIRED frame")
    if result.error is not None:
        problems.append("stream error: " + result.error.describe())
    sem(b, op, "interrupted stream stays valid", not problems, "; ".join(problems) or f"{' '.join(result.kinds())}")

    op = "SubscribeToTask"
    slow = send(b, "seed for subscribe", "slow_count", {"delay_ms": 900}, {"returnImmediately": True})
    if slow is not None:
        result = b.stream(op, pb.SubscribeToTaskRequest(id=slow.id), "Task first, then updates to terminal")
        problems = stream_invariants(result)
        if result.frames and result.frames[0].WhichOneof("payload") == "task" and result.frames[0].task.id != slow.id:
            problems.append("the snapshot is another task")
        if result.error is not None:
            problems.append("stream error: " + result.error.describe())
        sem(b, op, "Task first, then updates to terminal", not problems, "; ".join(problems) or
            f"{len(result.frames)} frames: {' '.join(result.kinds())} (3.1.6)")

    slow = send(b, "seed for resume", "slow_count", {"delay_ms": 900}, {"returnImmediately": True})
    if slow is not None:
        result = b.stream(op, pb.SubscribeToTaskRequest(id=slow.id, last_seen_generation=slow.generation),
                          "lastSeenGeneration resumes without a snapshot")
        problems = []
        kinds = result.kinds()
        if not kinds:
            problems.append("no frame")
        elif kinds[0] == "task":
            problems.append("opened with a Task snapshot although lastSeenGeneration was set (3.1.12)")
        generations = [h.frame_generation(f) for f in result.frames]
        problems += generation_problems(result.frames, after=slow.generation)
        if result.frames and h.frame_state(result.frames[-1]) not in h.TERMINAL:
            problems.append("did not reach a terminal status")
        if not result.closed:
            problems.append("the server did not close the stream after the terminal frame")
        if result.error is not None:
            problems.append("stream error: " + result.error.describe())
        sem(b, op, "lastSeenGeneration resumes without a snapshot", not problems, "; ".join(problems) or
            f"generations {generations} after {slow.generation}")


def run_push(b, env):
    tag = uid("hook")
    task = send(b, "seed for push configs", "slow_count", {"delay_ms": 1200}, {"returnImmediately": True})
    if task is None:
        return
    config = pb.TaskPushNotificationConfig(
        task_id=task.id, id=uid("cfg"), url=env.webhook.url(tag), token="tok-" + tag, protocol_version="1.1",
        authentication=pb.AuthenticationInfo(scheme="Bearer", credentials="cred-" + tag),
    )
    op = "CreateTaskPushNotificationConfig"
    created = b.expect(op, config, "create with token and authentication")
    if created is None:
        return
    problems = []
    for field in ("task_id", "id", "url", "token", "protocol_version"):
        if getattr(created, field) != getattr(config, field):
            problems.append(f"{field} is {getattr(created, field)!r}, sent {getattr(config, field)!r}")
    if created.authentication.scheme != "Bearer":
        problems.append(f"authentication.scheme is {created.authentication.scheme!r}")
    sem(b, op, "create with token and authentication", not problems, "; ".join(problems) or "echoes the config")

    got = b.expect("GetTaskPushNotificationConfig", pb.GetTaskPushNotificationConfigRequest(task_id=task.id, id=config.id), "by id")
    if got is not None:
        sem(b, "GetTaskPushNotificationConfig", "by id", got == created,
            "equals the created config" if got == created else
            str(ref.diff(json_format.MessageToDict(got), json_format.MessageToDict(created))))
    listed = b.expect("ListTaskPushNotificationConfigs",
                      pb.ListTaskPushNotificationConfigsRequest(task_id=task.id, page_size=10), "lists the task's configs")
    if listed is not None:
        ok = len(listed.configs) == 1 and listed.configs[0] == created
        sem(b, "ListTaskPushNotificationConfigs", "lists the task's configs", ok, f"{len(listed.configs)} config(s)")

    deliveries = env.webhook.wait(tag, lambda d: b"TASK_STATE_COMPLETED" in d["body"])
    problems, merged = [], {}
    if not deliveries:
        problems.append("no delivery reached the webhook")
    for index, delivery in enumerate(deliveries):
        try:
            value = ref.loads(delivery["body"])
        except Exception as exc:
            problems.append(f"delivery {index} is not JSON: {exc}")
            continue
        _msg, found = h.check_json(b.report, value, pb.StreamResponse)
        h.merge(merged, found, f"delivery {index}: ")
        if delivery["headers"].get("authorization") != "Bearer cred-" + tag:
            problems.append(f"delivery {index} Authorization is {delivery['headers'].get('authorization')!r} (4.3.3)")
    if deliveries:
        b.report.problems(b.name, "push delivery", "webhook payload is a StreamResponse (4.3.3)", merged, len(deliveries), "delivery body(ies)")
    sem(b, "push delivery", "webhook payload is a StreamResponse (4.3.3)", not problems, "; ".join(problems) or
        f"{len(deliveries)} deliveries carrying the config's credentials")

    op = "DeleteTaskPushNotificationConfig"
    request = pb.DeleteTaskPushNotificationConfigRequest(task_id=task.id, id=config.id)
    deleted = b.expect(op, request, "delete")
    if deleted is not None:
        listed = b.expect("ListTaskPushNotificationConfigs", pb.ListTaskPushNotificationConfigsRequest(task_id=task.id), "empty after delete")
        if listed is not None:
            sem(b, "ListTaskPushNotificationConfigs", "empty after delete", len(listed.configs) == 0, f"{len(listed.configs)} config(s)")
        again = b.unary(op, request, "delete is idempotent")
        sem(b, op, "delete is idempotent", again.error is None,
            "second delete succeeds (3.1.10 MUST be idempotent)" if again.error is None else again.error.describe())

    # A config supplied inline on SendMessage is equivalent to Create (3.1.12, 3.2.2).
    inline = uid("cfg")
    task = send(b, "inline taskPushNotificationConfig", "slow_count", {"delay_ms": 300},
                {"returnImmediately": True, "taskPushNotificationConfig": {"id": inline, "url": env.webhook.url(uid("hook")), "token": "t"}})
    if task is not None:
        listed = b.expect("ListTaskPushNotificationConfigs", pb.ListTaskPushNotificationConfigsRequest(task_id=task.id), "inline config is listed")
        if listed is not None:
            ids = [c.id for c in listed.configs]
            sem(b, "ListTaskPushNotificationConfigs", "inline config is listed", inline in ids, f"configs {ids}")
        await_state(b, task.id, h.TERMINAL)


def run_card(b, env):
    op = "GetExtendedAgentCard"
    card = b.expect(op, pb.GetExtendedAgentCardRequest(), "authenticated extended card")
    if card is None:
        return
    env.cards[b.name] = card
    problems = []
    if not card.capabilities.extended_agent_card:
        problems.append("capabilities.extendedAgentCard is not true although the operation is served (3.1.11)")
    if not card.capabilities.streaming:
        problems.append("capabilities.streaming is not true although streaming is served")
    if not card.capabilities.push_notifications:
        problems.append("capabilities.pushNotifications is not true although push configs are served (3.3.4)")
    declared = {(i.protocol_binding, i.url) for i in card.supported_interfaces}
    if not declared:
        problems.append("no supportedInterfaces")
    sem(b, op, "authenticated extended card", not problems, "; ".join(problems) or
        f"{len(card.skills)} skills, interfaces {sorted(i.protocol_binding for i in card.supported_interfaces)}")


def drain(live, done, timeout):
    """Reads the downlink until `done(frame)`, the stream ends, or the time is up."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        frame = live.next(0.5)
        if frame is not None and done(frame):
            return True
        if frame is None and (live.closed or getattr(live, "error", None) is not None):
            return False
    return False


def generation_problems(frames, after=None):
    """Spec 3.2.7: every mutation is exactly one event carrying the generation
    after it, so on a 1.1 stream the generations run N, N+1, N+2, ... with no
    repeat, no zero and no gap. StreamError frames carry no generation."""
    problems, last = [], after
    for index, frame in enumerate(frames):
        generation = h.frame_generation(frame)
        if generation is None:
            continue
        kind = frame.WhichOneof("payload")
        if generation == 0:
            problems.append(f"frame {index} ({kind}) carries generation 0")
        elif kind == "task":
            # A snapshot is not an event: it may restate the current
            # generation (11.7: a final Task MAY be resent), never an older one.
            if last is not None and generation < last:
                problems.append(f"frame {index} (task) generation {generation} goes back from {last}")
        elif last is not None and generation != last + 1:
            what = "repeats" if generation == last else "goes back from" if generation < last else "skips after"
            problems.append(f"frame {index} ({kind}) generation {generation} {what} {last}")
        last = generation if generation else last
    return problems


def live_task(frame):
    return frame.task if frame is not None and frame.WhichOneof("payload") == "task" else None


def run_live(b, env):
    op = "SendLiveMessage"

    # Opening with sendMessage: a Task snapshot that already reflects the message.
    vector = "open with sendMessage"
    first = pb.StreamRequest(send_message=send_request("slow_count", {"delay_ms": 600}))
    live = b.live(first, vector)
    if getattr(live, "error", None) is not None:
        sem(b, op, vector, False, "refused: " + live.error.describe())
        return
    frame = live.next()
    task = live_task(frame)
    problems = []
    if task is None:
        problems.append(f"first frame is {frame.WhichOneof('payload') if frame is not None else 'missing'}, not task")
    else:
        sent_id = first.send_message.message.message_id
        if not any(e.WhichOneof("entry") == "message" and e.message.message_id == sent_id for e in task.timeline):
            problems.append("the opening snapshot does not reflect the appended message (3.1.12)")
        problems += task_invariants(task)
        if task.status.state not in h.TERMINAL:
            drain(live, lambda f: h.frame_state(f) in h.TERMINAL, 10)
        states = [h.frame_state(f) for f in live.frames if h.frame_state(f) is not None]
        if not states or states[-1] not in h.TERMINAL:
            problems.append(f"the downlink did not reach a terminal status: {[state_name(s) for s in states]}")
        problems += generation_problems(live.frames)
    sem(b, op, vector, not problems, "; ".join(problems) or
        f"snapshot holds the sent message; frames: {' '.join(f.WhichOneof('payload') for f in live.frames)}; "
        f"generations {[h.frame_generation(f) for f in live.frames]}")
    live.close()

    # One session over an interrupted task: rejections keep the stream open,
    # and a 1.1 client receives its own message as a TaskMessageUpdateEvent.
    vector = "interrupted task session"
    first = pb.StreamRequest(send_message=send_request("create_note", {"body": "no title"}))
    live = b.live(first, vector)
    task = live_task(live.next())
    if task is None:
        sem(b, op, vector, False, "no opening Task snapshot")
    else:
        if task.status.state != pb.TASK_STATE_INPUT_REQUIRED:
            drain(live, lambda f: h.frame_state(f) == pb.TASK_STATE_INPUT_REQUIRED, 8)

        name = "later subscribe is rejected with a StreamError"
        answer = live.send(pb.StreamRequest(subscribe=pb.SubscribeToTaskRequest(id=task.id)))
        sem(b, op, name, *expect_live_rejection(b, live, answer))

        name = "request naming another task is rejected with a StreamError"
        other = send(b, "seed another task", "count_notes")
        answer = live.send(pb.StreamRequest(send_message=send_request(
            "count_notes", task_id=other.id if other is not None else "tsk-other", context_id=task.context_id)))
        sem(b, op, name, *expect_live_rejection(b, live, answer))

        name = "client message arrives as TaskMessageUpdateEvent"
        follow = pb.StreamRequest(send_message=send_request(
            "create_note", {"title": uid("live"), "body": "b"}, task_id=task.id, context_id=task.context_id))
        answer = live.send(follow)
        problems = live_ack_problems(b, answer, task.id, name) if answer is not None else []
        drain(live, lambda f: h.frame_state(f) in h.TERMINAL, 10)
        kinds = [f.WhichOneof("payload") for f in live.frames]
        updates = [f.message_update for f in live.frames if f.WhichOneof("payload") == "message_update"]
        sent_id = follow.send_message.message.message_id
        if not any(u.message.message_id == sent_id and u.task_id == task.id and u.generation > 0 for u in updates):
            problems.append(f"no messageUpdate for the follow-up message on the downlink (frames: {kinds})")
        states = [h.frame_state(f) for f in live.frames if h.frame_state(f) is not None]
        if not states or states[-1] != pb.TASK_STATE_COMPLETED:
            problems.append(f"did not complete: {[state_name(s) for s in states]}")
        problems += generation_problems(live.frames)
        sem(b, op, name, not problems, "; ".join(problems) or
            f"frames: {' '.join(kinds)}; generations {[h.frame_generation(f) for f in live.frames]}")
    live.close()

    # Opening with subscribe: snapshot when lastSeenGeneration is unset.
    slow = send(b, "seed for live subscribe", "slow_count", {"delay_ms": 800}, {"returnImmediately": True})
    if slow is not None:
        vector = "open with subscribe: Task snapshot first"
        live = b.live(pb.StreamRequest(subscribe=pb.SubscribeToTaskRequest(id=slow.id)), vector)
        snapshot = live_task(live.next())
        if snapshot is not None and snapshot.status.state in h.TERMINAL:
            pass
        drain(live, lambda f: h.frame_state(f) in h.TERMINAL, 8)
        problems = [] if snapshot is not None and snapshot.id == slow.id else ["no Task snapshot of the subscribed task first"]
        states = [h.frame_state(f) for f in live.frames if h.frame_state(f) is not None]
        if not states or states[-1] not in h.TERMINAL:
            problems.append(f"did not reach a terminal status: {[state_name(x) for x in states]}")
        problems += generation_problems(live.frames)
        sem(b, op, vector, not problems, "; ".join(problems) or
            f"frames: {' '.join(f.WhichOneof('payload') for f in live.frames)}; generations {[h.frame_generation(f) for f in live.frames]}")
        live.close()

    slow = send(b, "seed for live resume", "slow_count", {"delay_ms": 800}, {"returnImmediately": True})
    if slow is not None:
        vector = "open with subscribe and lastSeenGeneration: no snapshot"
        live = b.live(pb.StreamRequest(subscribe=pb.SubscribeToTaskRequest(id=slow.id, last_seen_generation=slow.generation)), vector)
        drain(live, lambda f: h.frame_state(f) in h.TERMINAL, 8)
        kinds = [f.WhichOneof("payload") for f in live.frames]
        generations = [h.frame_generation(f) for f in live.frames]
        problems = generation_problems(live.frames, after=slow.generation)
        if not kinds:
            problems.append("no frame")
        elif kinds[0] == "task":
            problems.append("opened with a Task snapshot although lastSeenGeneration was set")
        sem(b, op, vector, not problems, "; ".join(problems) or
            f"frames: {' '.join(kinds)}; generations {generations} after {slow.generation} (3.1.12)")
        live.close()

    # Subscribing to a task that does not exist: TaskNotFoundError (3.1.12 Errors).
    vector = "open with subscribe to an unknown task"
    live = b.live(pb.StreamRequest(subscribe=pb.SubscribeToTaskRequest(id="tsk-does-not-exist")), vector)
    error = getattr(live, "error", None)
    frame = None
    if error is None:
        frame = live.next(5)
        error = getattr(live, "error", None)
    if error is not None:
        outcome = h.Outcome(error=error)
        expect_a2a_error(b, op, vector, outcome, "TaskNotFoundError", "3.1.12", in_stream=True)
    else:
        sem(b, op, vector, False,
            f"no TaskNotFoundError; got {frame.WhichOneof('payload') if frame is not None else 'nothing'}"
            + (f" {frame.error.code!r}" if frame is not None and frame.WhichOneof("payload") == "error" else ""))
    live.close()


def expect_live_rejection(b, live, answer):
    """A rejected live request shows as a StreamError on the downlink, naming
    the request (3.1.12), and the stream stays open."""
    deadline = time.monotonic() + 6
    seen = len([f for f in live.frames if f.WhichOneof("payload") == "error"])
    while time.monotonic() < deadline:
        errors = [f.error for f in live.frames if f.WhichOneof("payload") == "error"]
        if len(errors) > seen:
            error = errors[-1]
            if not error.code:
                return False, "StreamError.code is REQUIRED and empty"
            if live.closed or getattr(live, "error", None) is not None:
                return False, f"StreamError {error.code!r} arrived but the stream ended"
            return True, f"StreamError code {error.code!r}, referenceId {error.reference_id!r}; stream still open"
        live.next(0.5)
    extra = ""
    if answer is not None:
        extra = f"; the uplink call answered HTTP {answer.status} {answer.body[:160]!r}"
    return False, "no StreamError on the downlink within 6s" + extra


def live_ack_problems(b, answer, task_id, vector):
    """An HTTP uplink call answers only the acknowledgement: the current Task
    (3.1.12). The operation's response type is StreamResponse."""
    problems = []
    if answer.status != 200:
        return [f"uplink call answered HTTP {answer.status}: {answer.body[:160]!r}"]
    if "text/event-stream" in answer.content_type:
        datas = [line[5:].strip() for line in answer.body.decode("utf-8").splitlines() if line.startswith("data:")]
        values = [ref.loads(d) for d in datas]
    else:
        values = [ref.loads(answer.body)]
    if len(values) != 1:
        return [f"uplink call answered {len(values)} events, the spec says only the acknowledgement"]
    payload, error, _ = b._unwrap_frame(values[0])
    if error is not None:
        return ["uplink call refused: " + error.describe()]
    message, found = h.check_json(b.report, payload, pb.StreamResponse)
    b.report.problems(b.name, "SendLiveMessage", vector + " (uplink ack)", found, 1, "uplink acknowledgement")
    if message is None or message.WhichOneof("payload") != "task" or message.task.id != task_id:
        problems.append("the uplink acknowledgement is not the current Task as a StreamResponse")
    return problems


def run_user_artifacts(b, env):
    """Client-written artifacts (SendMessageRequest.artifact_updates)."""
    op = "SendMessage"
    vector = "userArtifacts: client artifact_updates"
    card = env.cards.get(b.name)
    declared = card is not None and card.capabilities.user_artifacts
    request = send_request("count_notes")
    update = request.artifact_updates.add()
    update.artifact.artifact_id = uid("uart")
    update.artifact.name = "input.txt"
    update.artifact.role = pb.ROLE_USER
    update.artifact.parts.add().text = "client input"
    update.last_chunk = True
    outcome = b.unary(op, request, vector)
    if declared:
        if outcome.error is not None:
            sem(b, op, vector, False, "capabilities.userArtifacts is true but the send was refused: " + outcome.error.describe())
            return
        task = outcome.message.task
        mine = [a for a in task.artifacts if a.artifact_id == update.artifact.artifact_id]
        problems = []
        if not mine:
            problems.append("the client artifact is not on the task")
        elif mine[0].role != pb.ROLE_USER:
            problems.append(f"the client artifact's role is {pb.Role.Name(mine[0].role)}")
        elif mine[0].start_generation < 1:
            problems.append("the client artifact carries no startGeneration")
        sem(b, op, vector, not problems, "; ".join(problems) or
            f"ROLE_USER artifact stored at generation {mine[0].start_generation}")
    else:
        # Not declared: the proto says the field "requires capabilities.user_artifacts".
        if outcome.error is None:
            sem(b, op, vector, False,
                "capabilities.userArtifacts is not declared, yet artifact_updates were accepted without an error")
        else:
            expect_a2a_error(b, op, vector, outcome, "UnsupportedOperationError", "3.3.4 / proto SendMessageRequest.artifact_updates")


# -- errors ----------------------------------------------------------------------


def _judge(b, error, jsonrpc_code, grpc_status, http_status, reason):
    problems = list(error.problems)
    if b.kind == "grpc":
        if error.code != grpc_status:
            problems.append(f"gRPC status {error.code}, spec says {grpc_status}")
    elif b.kind == "rest":
        if error.http_status is not None and error.http_status != http_status:
            problems.append(f"HTTP {error.http_status}, spec says {http_status}")
        if error.http_status is None and error.code != http_status:
            problems.append(f"error.code {error.code}, spec says {http_status}")
        if error.status_name != grpc_status:
            problems.append(f"error.status {error.status_name!r}, spec says {grpc_status!r}")
    else:
        if jsonrpc_code is not None and error.code != jsonrpc_code:
            problems.append(f"JSON-RPC code {error.code}, spec says {jsonrpc_code}")
        if error.http_status not in (None, 200) and jsonrpc_code is not None and jsonrpc_code > -32100:
            problems.append(f"HTTP {error.http_status} around a JSON-RPC error object")
    if reason is not None:
        infos = error.error_infos
        if not any(i.reason == reason and i.domain == DOMAIN for i in infos):
            problems.append(
                f"no google.rpc.ErrorInfo with reason {reason} and domain {DOMAIN} "
                f"(got {[(i.reason, i.domain) for i in infos]})"
            )
    return problems


def expect_a2a_error(b, operation, vector, outcome, name, section, in_stream=False):
    jsonrpc_code, grpc_status, http_status, reason = A2A_ERRORS[name]
    if outcome.error is None:
        return b.report.add(b.name, operation, vector, "error", False, f"no error; the spec ({section}) says {name}")
    error = outcome.error
    if in_stream and b.kind == "rest":
        error.http_status = None
    problems = _judge(b, error, jsonrpc_code, grpc_status, http_status, reason)
    return b.report.add(b.name, operation, vector, "error", not problems,
                        ("; ".join(problems) + " | got " if problems else f"{name} ({section}; 5.4): ") + error.describe())


def expect_generic_error(b, operation, vector, outcome, category, section="3.3.2"):
    jsonrpc_code, grpc_status, http_status = GENERIC_ERRORS[category]
    if outcome.error is None:
        return b.report.add(b.name, operation, vector, "error", False, f"no error; the spec ({section}) says a {category} error")
    error = outcome.error
    problems = list(error.problems)
    if b.kind == "grpc" and error.code != grpc_status:
        problems.append(f"gRPC status {error.code}, spec says {grpc_status}")
    if b.kind == "rest":
        if error.http_status != http_status:
            problems.append(f"HTTP {error.http_status}, spec says {http_status}")
        if error.status_name != grpc_status:
            problems.append(f"error.status {error.status_name!r}, spec says {grpc_status!r}")
    if b.kind == "jsonrpc":
        if jsonrpc_code is not None and error.code != jsonrpc_code:
            problems.append(f"JSON-RPC code {error.code}, spec says {jsonrpc_code}")
        if jsonrpc_code is None and error.http_status != http_status and not isinstance(error.code, int):
            problems.append(f"HTTP {error.http_status} without a JSON-RPC error; spec says HTTP {http_status} or a custom error")
    return b.report.add(b.name, operation, vector, "error", not problems,
                        ("; ".join(problems) + " | got " if problems else f"{category} error ({section}): ") + error.describe())


def run_errors(b, env):
    missing = "tsk-does-not-exist"

    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "unknown task")
    expect_a2a_error(b, "GetTask", "unknown task", outcome, "TaskNotFoundError", "3.1.3")
    outcome = b.unary("CancelTask", pb.CancelTaskRequest(id=missing), "unknown task")
    expect_a2a_error(b, "CancelTask", "unknown task", outcome, "TaskNotFoundError", "3.1.5")
    result = b.stream("SubscribeToTask", pb.SubscribeToTaskRequest(id=missing), "unknown task", wait=8, record=False)
    expect_a2a_error(b, "SubscribeToTask", "unknown task", result, "TaskNotFoundError", "3.1.6")
    outcome = b.unary("SendMessage", send_request("count_notes", task_id=missing), "message to an unknown task")
    expect_a2a_error(b, "SendMessage", "message to an unknown task", outcome, "TaskNotFoundError", "3.1.1")
    result = b.stream("SendStreamingMessage", send_request("count_notes", task_id=missing), "message to an unknown task", wait=8, record=False)
    expect_a2a_error(b, "SendStreamingMessage", "message to an unknown task", result, "TaskNotFoundError", "3.1.2")

    done = send(b, "seed a completed task", "count_notes")
    if done is not None:
        outcome = b.unary("CancelTask", pb.CancelTaskRequest(id=done.id), "completed task is not cancelable")
        expect_a2a_error(b, "CancelTask", "completed task is not cancelable", outcome, "TaskNotCancelableError", "3.1.5")
        result = b.stream("SubscribeToTask", pb.SubscribeToTaskRequest(id=done.id), "terminal task", wait=8, record=False)
        expect_a2a_error(b, "SubscribeToTask", "terminal task", result, "UnsupportedOperationError", "3.1.6")
        outcome = b.unary("SendMessage", send_request("count_notes", task_id=done.id, context_id=done.context_id),
                          "message to a terminal task")
        expect_a2a_error(b, "SendMessage", "message to a terminal task", outcome, "UnsupportedOperationError", "3.1.1 / 3.1.2")

        # Another caller's task is indistinguishable from a missing one (3.3.2).
        outcome = b.unary("GetTask", pb.GetTaskRequest(id=done.id), "another caller's task", token="reader")
        expect_a2a_error(b, "GetTask", "another caller's task", outcome, "TaskNotFoundError", "3.3.2")

    parked = send(b, "seed an interrupted task", "create_note", {"body": "no title"})
    if parked is not None:
        stale = send_request("create_note", {"title": uid("t")}, {"ifGenerationMatch": str(parked.generation + 7)},
                             task_id=parked.id, context_id=parked.context_id)
        outcome = b.unary("SendMessage", stale, "ifGenerationMatch mismatch")
        ok = expect_a2a_error(b, "SendMessage", "ifGenerationMatch mismatch", outcome, "TaskGenerationMismatchError", "3.2.2 / 11.6")
        if ok:
            after = get(b, "task untouched after a generation conflict", parked.id)
            if after is not None:
                sem(b, "GetTask", "task untouched after a generation conflict", after.generation == parked.generation,
                    f"generation {parked.generation} -> {after.generation}")
        result = b.stream("SendStreamingMessage", stale, "ifGenerationMatch mismatch", wait=8, record=False)
        expect_a2a_error(b, "SendStreamingMessage", "ifGenerationMatch mismatch", result, "TaskGenerationMismatchError", "3.2.2")

    fresh = send(b, "ifGenerationMatch is ignored for a new task", "count_notes", None, {"ifGenerationMatch": "41"})
    if fresh is not None:
        sem(b, "SendMessage", "ifGenerationMatch is ignored for a new task", fresh.status.state == pb.TASK_STATE_COMPLETED,
            f"{state_name(fresh.status.state)} (3.2.2: MUST be ignored when the task does not exist yet)")

    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "A2A-Version 9.9", version="9.9")
    expect_a2a_error(b, "GetTask", "A2A-Version 9.9", outcome, "VersionNotSupportedError", "3.6.2")

    outcome = b.unary("SendMessage", pb.SendMessageRequest(), "no message")
    expect_generic_error(b, "SendMessage", "no message", outcome, "validation")
    empty = pb.SendMessageRequest(message=pb.Message(message_id=uid(), role=pb.ROLE_USER))
    outcome = b.unary("SendMessage", empty, "message without parts")
    expect_generic_error(b, "SendMessage", "message without parts", outcome, "validation")
    outcome = b.unary("ListTasks", pb.ListTasksRequest(page_size=-1), "negative pageSize")
    expect_generic_error(b, "ListTasks", "negative pageSize", outcome, "validation", "3.1.4 / 6.5")
    outcome = b.unary("ListTasks", pb.ListTasksRequest(page_token="not-a-token"), "malformed pageToken")
    expect_generic_error(b, "ListTasks", "malformed pageToken", outcome, "validation", "3.1.4")

    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "no credentials", token=None)
    expect_generic_error(b, "GetTask", "no credentials", outcome, "authentication")
    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "token without the scope", token="unscoped")
    expect_generic_error(b, "GetTask", "token without the scope", outcome, "authorization")

    for rpc, request in (
        ("GetTaskPushNotificationConfig", pb.GetTaskPushNotificationConfigRequest(task_id=missing, id="cfg")),
        ("ListTaskPushNotificationConfigs", pb.ListTaskPushNotificationConfigsRequest(task_id=missing)),
        ("CreateTaskPushNotificationConfig", pb.TaskPushNotificationConfig(task_id=missing, url=env.webhook.url("none"))),
        ("DeleteTaskPushNotificationConfig", pb.DeleteTaskPushNotificationConfigRequest(task_id=missing, id="cfg")),
    ):
        outcome = b.unary(rpc, request, "unknown task")
        expect_a2a_error(b, rpc, "unknown task", outcome, "TaskNotFoundError", "3.1.7-3.1.10")

    if done is not None:
        outcome = b.unary("GetTaskPushNotificationConfig",
                          pb.GetTaskPushNotificationConfigRequest(task_id=done.id, id="cfg-missing"), "unknown config")
        if outcome.error is None:
            b.report.add(b.name, "GetTaskPushNotificationConfig", "unknown config", "error", False, "no error for a config that does not exist")
        else:
            problems = _judge(b, outcome.error, None, "NOT_FOUND", 404, None)
            if b.kind == "jsonrpc" and not isinstance(outcome.error.code, int):
                problems.append("no JSON-RPC error code")
            b.report.add(b.name, "GetTaskPushNotificationConfig", "unknown config", "error", not problems,
                         ("; ".join(problems) + " | got " if problems else "resource error (3.3.2): ") + outcome.error.describe())


def run_jsonrpc_protocol_errors(b):
    """JSON-RPC 2.0 standard codes, spec 9.5."""
    cases = [
        ("invalid JSON", b"{not json", -32700),
        ("not a request object", b'{"jsonrpc":"2.0","id":1}', -32600),
        ("unknown method", b'{"jsonrpc":"2.0","id":1,"method":"NoSuchMethod","params":{}}', -32601),
        ("params of the wrong type", b'{"jsonrpc":"2.0","id":1,"method":"GetTask","params":{"id":17}}', -32602),
    ]
    for vector, body, code in cases:
        error = b.raw_call(body)
        problems = list(error.problems)
        if error.code != code:
            problems.append(f"code {error.code}, spec 9.5 says {code}")
        b.report.add(b.name, "JSON-RPC 2.0", vector, "error", not problems,
                     ("; ".join(problems) + " | got " if problems else f"{code} (9.5): ") + error.describe())


def run_public_cards(env, report):
    """The well-known Agent Card at the root and at every mount (spec 8, 14.3)."""
    base = env.args.http.rstrip("/")
    cards = {}
    for mount in ("", "/a2a", "/jsonrpc", "/rest"):
        url = base + mount + "/.well-known/agent-card.json"
        resp = h.http_call("GET", url, {"accept": "application/json"})
        name = "GET " + (mount or "") + "/.well-known/agent-card.json"
        if resp.status != 200:
            report.add("agent-card", name, "public card", "call", False, f"HTTP {resp.status}")
            continue
        try:
            value = resp.json()
        except Exception as exc:
            report.add("agent-card", name, "public card", "strict", False, str(exc))
            continue
        h.note_raw_canonical(report, resp.body, value)
        card, problems = h.check_json(report, value, pb.AgentCard)
        report.problems("agent-card", name, "public card", problems, 1, "AgentCard")
        if card is not None:
            cards[mount] = card
            versions = sorted({i.protocol_version for i in card.supported_interfaces})
            bindings = sorted({i.protocol_binding for i in card.supported_interfaces})
            problems = []
            if "1.1" not in versions:
                problems.append(
                    f"supportedInterfaces declare protocolVersion {versions}; the server answers A2A-Version 1.1 "
                    "and serves SendLiveMessage, so a 1.1 interface must be declared (3.6, 8.2.1)"
                )
            if not {"JSONRPC", "GRPC", "HTTP+JSON"} <= set(bindings):
                problems.append(f"declared bindings {bindings} (5.2: MUST declare all supported protocols)")
            report.add("agent-card", name, "declares what is served", "semantics", not problems,
                       "; ".join(problems) or f"bindings {bindings}, versions {versions}")
    return cards


# -- cross-binding ---------------------------------------------------------------


def run_cross(env, report):
    """Spec 5.1: the same logical task is the same message on every binding."""
    names = [b.name for b in env.bindings]
    by_kind = {}
    for b in env.bindings:
        by_kind.setdefault(b.kind, b)
    full = [by_kind[k] for k in ("grpc", "rest", "jsonrpc") if k in by_kind]
    if len(full) < 2:
        return
    for creator in full:
        task = send(creator, "seed for the cross-binding read", "create_note", {"title": uid("cross"), "body": "b"})
        if task is None:
            continue
        seen = {}
        for reader in full:
            got = reader.unary("GetTask", pb.GetTaskRequest(id=task.id), f"task created over {creator.name}", record=True)
            if got.message is not None:
                seen[reader.name] = got.message
            else:
                report.add("cross-binding", "GetTask", f"task created over {creator.name}", "call", False,
                           f"{reader.name}: " + (got.error.describe() if got.error else "unparseable"))
        reference_bytes = None
        problems = []
        for name, message in seen.items():
            encoded = message.SerializeToString(deterministic=True)
            if reference_bytes is None:
                reference_bytes, reference_name, reference_message = encoded, name, message
            elif encoded != reference_bytes:
                problems.append(
                    f"{name} differs from {reference_name}: "
                    + str(ref.diff(json_format.MessageToDict(message), json_format.MessageToDict(reference_message)))
                )
        if seen and task.SerializeToString(deterministic=True) != reference_bytes:
            problems.append(
                f"GetTask over {reference_name} differs from the SendMessage answer over {creator.name}: "
                + str(ref.diff(json_format.MessageToDict(reference_message), json_format.MessageToDict(task)))
            )
        report.add("cross-binding", "GetTask", f"task created over {creator.name}", "identical", not problems,
                   "; ".join(problems) or f"identical upstream Task ({len(reference_bytes or b'')} bytes) over {sorted(seen)}")

        listings = {}
        for reader in full:
            got = reader.unary("ListTasks", pb.ListTasksRequest(context_id=task.context_id, include_artifacts=True),
                               f"context of the task created over {creator.name}")
            if got.message is not None:
                listings[reader.name] = got.message.SerializeToString(deterministic=True)
        same = len(set(listings.values())) == 1 and len(listings) == len(full)
        report.add("cross-binding", "ListTasks", f"context of the task created over {creator.name}", "identical", same,
                   f"identical ListTasksResponse over {sorted(listings)}" if same else f"{len(set(listings.values()))} distinct answers over {sorted(listings)}")

    cards = {name: card.SerializeToString(deterministic=True) for name, card in env.cards.items() if name in [b.name for b in full]}
    if len(cards) >= 2:
        same = len(set(cards.values())) == 1
        detail = f"identical AgentCard over {sorted(cards)}"
        if not same:
            first_name = sorted(cards)[0]
            detail = "; ".join(
                f"{name} vs {first_name}: " + str(ref.diff(json_format.MessageToDict(env.cards[name]), json_format.MessageToDict(env.cards[first_name])))
                for name in sorted(cards)[1:] if cards[name] != cards[first_name]
            )
        report.add("cross-binding", "GetExtendedAgentCard", "same card on every binding", "identical", same, detail)

    # One error, three bindings: the same A2A error type everywhere (5.1, 5.4).
    del names


# -- coverage --------------------------------------------------------------------


def run_coverage(env, report):
    reachable = ref.reachable_fields()
    missing = [f for f in reachable if f not in report.coverage]
    unexplained = [f for f in missing if f not in UNREACHABLE]
    stale = [f for f in UNREACHABLE if f in report.coverage]
    report.add("coverage", "response fields", "every field reachable from an RPC response",
               "coverage", not unexplained,
               f"{len(reachable) - len(missing)} of {len(reachable)} observed set on the wire; "
               f"{len(missing) - len(unexplained)} unreachable with a stated reason"
               + (f"; UNEXPLAINED: {unexplained}" if unexplained else ""))
    if stale:
        report.add("coverage", "response fields", "unreachable list is current", "coverage", False,
                   f"listed as unreachable but observed: {stale}")

    wanted = ref.request_fields()
    unsent = [f for f in wanted if f not in report.request_coverage]
    unexplained = [f for f in unsent if f.split(".")[1] not in UNSENT]
    report.add("coverage", "request fields", "every field of every RPC request", "coverage", not unexplained,
               f"{len(wanted) - len(unsent)} of {len(wanted)} sent; {len(unsent) - len(unexplained)} unsent with a stated reason"
               + (f"; UNEXPLAINED: {unexplained}" if unexplained else ""))

    rpcs = [m.name for m in ref.SERVICE.methods]
    for b in env.bindings:
        if not b.full:
            continue
        called = {row["operation"] for row in report.rows if row["binding"] == b.name}
        absent = [rpc for rpc in rpcs if rpc not in called]
        report.add("coverage", b.name, "every RPC of lf.a2a.v1.A2AService", "coverage", not absent,
                   f"{len(rpcs) - len(absent)} of {len(rpcs)} RPCs exercised" + (f"; missing {absent}" if absent else ""))
    return {
        "response_fields": {"reachable": len(reachable), "observed": len(reachable) - len(missing),
                            "unreachable": {f: UNREACHABLE.get(f, "UNEXPLAINED") for f in missing}},
        "request_fields": {"total": len(wanted), "sent": len(wanted) - len(unsent),
                           "unsent": {f: UNSENT.get(f.split(".")[1], "UNEXPLAINED") for f in unsent}},
    }


# -- main ------------------------------------------------------------------------


def guarded(report, b, name, fn, env):
    try:
        fn(b, env)
    except Exception as exc:  # a crash in a vector is a failed row, not a lost run
        import traceback

        where = traceback.extract_tb(exc.__traceback__)[-1]
        report.add(b.name, name, "vector group", "call", False,
                   f"{type(exc).__name__}: {exc} ({where.filename.split('/')[-1]}:{where.lineno})")


def print_matrix(report, coverage, out):
    rows = report.rows
    widths = [max(len(str(r[k])) for r in rows + [{"binding": "BINDING", "operation": "OPERATION", "vector": "VECTOR", "check": "CHECK", "status": "STATUS"}])
              for k in ("binding", "operation", "vector", "check", "status")]
    header = ("BINDING", "OPERATION", "VECTOR", "CHECK", "STATUS")
    out.write("  ".join(h_.ljust(w) for h_, w in zip(header, widths)) + "  DETAIL\n")
    for row in rows:
        cells = [str(row[k]).ljust(w) for k, w in zip(("binding", "operation", "vector", "check", "status"), widths)]
        detail = row["detail"] if row["status"] != "pass" else row["detail"][:140]
        out.write("  ".join(cells) + "  " + detail + "\n")
    out.write("\n")
    bindings = []
    for row in rows:
        if row["binding"] not in bindings:
            bindings.append(row["binding"])
    out.write(f"{'BINDING':<16}{'pass':>6}{'fail':>6}{'warn':>6}{'skip':>6}\n")
    for name in bindings:
        counts = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
        for row in rows:
            if row["binding"] == name:
                counts[row["status"]] += 1
        out.write(f"{name:<16}{counts['pass']:>6}{counts['fail']:>6}{counts['warn']:>6}{counts['skip']:>6}\n")
    total = report.summary()
    out.write(f"{'total':<16}{total['pass']:>6}{total['fail']:>6}{total['warn']:>6}{total['skip']:>6}\n")
    out.write(f"\n{report.raw_canonical[0]} of {report.raw_canonical[1]} JSON bodies were already in RFC 8785 form as sent\n")
    fields = coverage["response_fields"]
    out.write(f"{fields['observed']} of {fields['reachable']} response fields observed; "
              f"{len(fields['unreachable'])} unreachable (reasons in the JSON report)\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--http", required=True, help="base URL of the simulation server's HTTP listener")
    parser.add_argument("--grpc", required=True, help="host:port of the gRPC endpoint")
    parser.add_argument("--report", help="write the JSON report to this file")
    parser.add_argument("--json", action="store_true", help="print the JSON report instead of the matrix")
    parser.add_argument("--writer-token", default="sim-writer-token")
    parser.add_argument("--reader-token", default="sim-reader-token")
    parser.add_argument("--unscoped-token", default="sim-unscoped-token")
    parser.add_argument("--trace", action="store_true", help="print each row to stderr as it is recorded")
    parser.add_argument("--groups", help="debugging: comma-separated vector groups (card,send,get,streams,push,live,artifacts,errors,cross)")
    parser.add_argument("--only", help="comma-separated bindings to run: grpc,http+json,jsonrpc,jsonrpc:/jsonrpc")
    args = parser.parse_args(argv)

    report = h.Report()
    report.trace = sys.stderr if args.trace else None
    tokens = {"writer": args.writer_token, "reader": args.reader_token, "unscoped": args.unscoped_token}
    base = args.http.rstrip("/")
    bindings = [
        h.GrpcBinding(report, tokens, args.grpc),
        h.RestBinding(report, tokens, base + "/rest"),
        h.JsonRpcBinding(report, tokens, base + "/a2a", "jsonrpc"),
        h.JsonRpcBinding(report, tokens, base + "/jsonrpc", "jsonrpc:/jsonrpc"),
    ]
    for b in bindings:
        b.full = b.name != "jsonrpc:/jsonrpc"
    if args.only:
        bindings = [b for b in bindings if b.name in args.only.split(",")]
    env = Env(report, bindings, args, Webhook())
    env.cards = {}

    if not args.groups:
        run_public_cards(env, report)
    groups = [
        ("card", "GetExtendedAgentCard", run_card, True),
        ("send", "SendMessage", run_send, False),
        ("get", "GetTask", run_get_list, False),
        ("streams", "SendStreamingMessage", run_streams, False),
        ("push", "CreateTaskPushNotificationConfig", run_push, True),
        ("live", "SendLiveMessage", run_live, True),
        ("artifacts", "SendMessage", run_user_artifacts, True),
    ]
    wanted = set(args.groups.split(",")) if args.groups else None
    for b in bindings:
        for group, operation, fn, full_only in groups:
            if (wanted is None or group in wanted) and (b.full or not full_only):
                guarded(report, b, operation, fn, env)
        if wanted is None or "errors" in wanted:
            guarded(report, b, "errors", run_errors if b.full else run_errors_core, env)
            if b.kind == "jsonrpc":
                run_jsonrpc_protocol_errors(b)
    if wanted is not None and "cross" not in wanted:
        print_matrix(report, {"response_fields": {"observed": 0, "reachable": 0, "unreachable": {}}}, sys.stdout)
        return 1 if report.summary()["fail"] else 0
    try:
        run_cross(env, report)
    except Exception as exc:
        report.add("cross-binding", "GetTask", "vector group", "call", False, f"{type(exc).__name__}: {exc}")
    coverage = run_coverage(env, report)

    summary = report.summary()
    document = {
        "reference": {"spec": SPEC, **ref.proto_source()},
        "target": {"http": args.http, "grpc": args.grpc},
        "summary": summary,
        "normalisations": NORMALISATIONS,
        "not_normalised": NOT_NORMALISED,
        "coverage": coverage,
        "raw_canonical_json_bodies": {"already_canonical": report.raw_canonical[0], "total": report.raw_canonical[1]},
        "rows": report.rows,
    }
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(document, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    if args.json:
        json.dump(document, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        print_matrix(report, coverage, sys.stdout)
    return 1 if summary["fail"] else 0


def run_errors_core(b, env):
    """The owner-scoped `/jsonrpc` mount serves the task methods only."""
    missing = "tsk-does-not-exist"
    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "unknown task")
    expect_a2a_error(b, "GetTask", "unknown task", outcome, "TaskNotFoundError", "3.1.3")
    outcome = b.unary("CancelTask", pb.CancelTaskRequest(id=missing), "unknown task")
    expect_a2a_error(b, "CancelTask", "unknown task", outcome, "TaskNotFoundError", "3.1.5")
    done = send(b, "seed a completed task", "count_notes")
    if done is not None:
        outcome = b.unary("CancelTask", pb.CancelTaskRequest(id=done.id), "completed task is not cancelable")
        expect_a2a_error(b, "CancelTask", "completed task is not cancelable", outcome, "TaskNotCancelableError", "3.1.5")
    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "A2A-Version 9.9", version="9.9")
    expect_a2a_error(b, "GetTask", "A2A-Version 9.9", outcome, "VersionNotSupportedError", "3.6.2")
    outcome = b.unary("SendMessage", pb.SendMessageRequest(), "no message")
    expect_generic_error(b, "SendMessage", "no message", outcome, "validation")
    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "no credentials", token=None)
    expect_generic_error(b, "GetTask", "no credentials", outcome, "authentication")
    outcome = b.unary("GetTask", pb.GetTaskRequest(id=missing), "token without the scope", token="unscoped")
    expect_generic_error(b, "GetTask", "token without the scope", outcome, "authorization")


if __name__ == "__main__":
    sys.exit(main())
