#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""The v1.0 half of the parity check: the same server, asked with
`A2A-Version: 1.0`, compared with stubs generated from the upstream
`v1.0.1:specification/a2a.proto`.

A v1.0 client must see the v1.0 wire: the upstream v1.0.1 types parse every
answer strictly, so a v1.1-only member (`generation`, `timeline`,
`startGeneration`, `messageUpdate`, ...) is an unknown field and fails.

`parity.py` runs this file in its own process, because the v1.0.1 and v1.1
protos declare the same package and cannot share one descriptor pool. It
prints its rows as JSON on standard output.

    A2A_PARITY_GEN=$VENV/a2a_v1_0_gen parity_v1_0.py --http URL --grpc HOST:PORT
"""

import argparse
import json
import sys
import time
import uuid

sys.dont_write_bytecode = True

from google.protobuf import json_format  # noqa: E402

import harness as h  # noqa: E402
import reference as ref  # noqa: E402
from reference import pb  # noqa: E402

V = "1.0"
TERMINAL = h.TERMINAL


def uid(prefix="m"):
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def send_request(skill, data=None, configuration=None, task_id=None, context_id=None):
    body = {"messageId": uid(), "role": "ROLE_USER", "parts": [{"data": data or {}}], "metadata": {"skill": skill}}
    if task_id:
        body["taskId"] = task_id
    if context_id:
        body["contextId"] = context_id
    request = pb.SendMessageRequest(message=json_format.ParseDict(body, pb.Message()))
    if configuration:
        json_format.ParseDict(configuration, request.configuration)
    return request


def run(b, report):
    def sem(operation, vector, ok, detail):
        report.add(b.name, operation, vector, "semantics", bool(ok), detail)

    def send(vector, *args, **kw):
        reply = b.expect("SendMessage", send_request(*args, **kw), vector, version=V)
        return reply.task if reply is not None and reply.WhichOneof("payload") == "task" else None

    task = send("1.0 client: blocking send", "count_notes")
    if task is None:
        return
    sem("SendMessage", "1.0 client: blocking send",
        task.status.state == pb.TASK_STATE_COMPLETED and len(task.artifacts) == 1 and len(task.history) >= 1,
        f"{pb.TaskState.Name(task.status.state)}, {len(task.artifacts)} artifact, {len(task.history)} history messages, no v1.1 member")

    got = b.expect("GetTask", pb.GetTaskRequest(id=task.id, history_length=1), "1.0 client: historyLength 1", version=V)
    if got is not None:
        sem("GetTask", "1.0 client: historyLength 1", len(got.history) == 1, f"{len(got.history)} history message")

    page = b.expect("ListTasks", pb.ListTasksRequest(context_id=task.context_id, include_artifacts=True),
                    "1.0 client: by context", version=V)
    if page is not None:
        sem("ListTasks", "1.0 client: by context", len(page.tasks) == 1 and page.total_size == 1, f"{len(page.tasks)} task")

    slow = send("1.0 client: returnImmediately", "slow_count", {"delay_ms": 30000}, {"returnImmediately": True})
    if slow is not None:
        canceled = b.expect("CancelTask", pb.CancelTaskRequest(id=slow.id), "1.0 client: cancel", version=V)
        if canceled is not None:
            sem("CancelTask", "1.0 client: cancel", canceled.status.state == pb.TASK_STATE_CANCELED,
                pb.TaskState.Name(canceled.status.state))

    send("1.0 client: seed a note", "create_note", {"title": uid("v10"), "body": "b"})
    result = b.stream("SendStreamingMessage", send_request("list_notes", {"stream": True}),
                      "1.0 client: task, artifact chunks, terminal status", version=V)
    kinds = result.kinds()
    ok = bool(kinds) and kinds[0] == "task" and "artifact_update" in kinds and h.frame_state(result.frames[-1]) in TERMINAL
    sem("SendStreamingMessage", "1.0 client: task, artifact chunks, terminal status", ok and result.error is None,
        f"frames: {' '.join(kinds)}" + (f"; error {result.error.describe()}" if result.error else ""))

    slow = send("1.0 client: seed for subscribe", "slow_count", {"delay_ms": 700}, {"returnImmediately": True})
    if slow is not None:
        result = b.stream("SubscribeToTask", pb.SubscribeToTaskRequest(id=slow.id), "1.0 client: Task first, then terminal", version=V)
        kinds = result.kinds()
        ok = bool(kinds) and kinds[0] == "task" and h.frame_state(result.frames[-1]) in TERMINAL
        sem("SubscribeToTask", "1.0 client: Task first, then terminal", ok, f"frames: {' '.join(kinds)}")

    if b.name.endswith("/jsonrpc"):
        return
    parked = send("1.0 client: seed for push configs", "create_note", {"body": "no title"})
    if parked is not None:
        config = pb.TaskPushNotificationConfig(task_id=parked.id, id=uid("cfg"), url="http://127.0.0.1:9/hook/v10", token="t")
        created = b.expect("CreateTaskPushNotificationConfig", config, "1.0 client: create", version=V)
        got = b.expect("GetTaskPushNotificationConfig",
                       pb.GetTaskPushNotificationConfigRequest(task_id=parked.id, id=config.id), "1.0 client: get", version=V)
        listed = b.expect("ListTaskPushNotificationConfigs",
                          pb.ListTaskPushNotificationConfigsRequest(task_id=parked.id), "1.0 client: list", version=V)
        if created is not None and got is not None and listed is not None:
            sem("ListTaskPushNotificationConfigs", "1.0 client: list",
                got == created and len(listed.configs) == 1, f"{len(listed.configs)} config, get equals create: {got == created}")
        b.expect("DeleteTaskPushNotificationConfig",
                 pb.DeleteTaskPushNotificationConfigRequest(task_id=parked.id, id=config.id), "1.0 client: delete", version=V)
    b.expect("GetExtendedAgentCard", pb.GetExtendedAgentCardRequest(), "1.0 client: extended card", version=V)

    # The error table is the same in v1.0.1 (5.4): 404 / 400 / NOT_FOUND / FAILED_PRECONDITION.
    outcome = b.unary("GetTask", pb.GetTaskRequest(id="tsk-does-not-exist"), "1.0 client: unknown task", version=V)
    error = outcome.error
    expected = {"grpc": "NOT_FOUND", "rest": 404, "jsonrpc": -32001}[b.kind]
    ok = error is not None and error.code == expected and not error.problems and any(
        i.reason == "TASK_NOT_FOUND" and i.domain == "a2a-protocol.org" for i in error.error_infos)
    report.add(b.name, "GetTask", "1.0 client: unknown task", "error", ok,
               (error.describe() if error else "no error") + " (v1.0.1 5.4)")
    done = send("1.0 client: seed a completed task", "count_notes")
    if done is not None:
        outcome = b.unary("CancelTask", pb.CancelTaskRequest(id=done.id), "1.0 client: completed task is not cancelable", version=V)
        error = outcome.error
        expected = {"grpc": "FAILED_PRECONDITION", "rest": 400, "jsonrpc": -32002}[b.kind]
        ok = error is not None and error.code == expected and not error.problems
        report.add(b.name, "CancelTask", "1.0 client: completed task is not cancelable", "error", ok,
                   (error.describe() if error else "no error") + " (v1.0.1 5.4)")
    time.sleep(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", required=True)
    parser.add_argument("--grpc", required=True)
    parser.add_argument("--writer-token", default="sim-writer-token")
    args = parser.parse_args()
    report = h.Report()
    tokens = {"writer": args.writer_token}
    base = args.http.rstrip("/")
    bindings = [
        h.GrpcBinding(report, tokens, args.grpc),
        h.RestBinding(report, tokens, base + "/rest"),
        h.JsonRpcBinding(report, tokens, base + "/a2a", "jsonrpc"),
        h.JsonRpcBinding(report, tokens, base + "/jsonrpc", "jsonrpc:/jsonrpc"),
    ]
    for b in bindings:
        try:
            run(b, report)
        except Exception as exc:
            report.add(b.name, "v1.0", "vector group", "call", False, f"{type(exc).__name__}: {exc}")
    for row in report.rows:
        row["vector"] = f"{row['binding']}: {row['vector']}"
        row["binding"] = "v1.0"
    json.dump({"reference": ref.proto_source(), "rows": report.rows}, sys.stdout)


if __name__ == "__main__":
    main()
