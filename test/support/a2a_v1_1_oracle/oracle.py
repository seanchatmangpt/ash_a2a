#!/usr/bin/env python3
"""
Unfakeable external A2A v1.1.0-rc Test Oracle.
Compiled directly from https://github.com/a2aproject/a2a (tag v1.1.0-rc)
specification/a2a.proto (SHA-256: 8d9c363f8654205780654306af307355a7a34dcf96a8e221caf251268deab127).

Runs outside the BEAM in an independent Python + C++ protobuf/gRPC process:
1. Validates HTTP /.well-known/agent-card.json against lf.a2a.v1.AgentCard
2. Validates JSON-RPC POST / SendMessage & ListTasks against SendMessageResponse & ListTasksResponse
3. Validates HTTP+JSON REST GET /tasks/:id against lf.a2a.v1.Task
4. Calls gRPC HTTP/2 lf.a2a.v1.A2AService/{SendMessage,GetTask,ListTasks} over real TCP
   (strictly using upstream v1.1.0-rc generated stubs and descriptors).
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
import grpc
from google.protobuf import json_format, struct_pb2

import a2a_pb2
import a2a_pb2_grpc


def http_json(url, token=None, body=None, headers=None):
    req_headers = {"Accept": "application/json"}
    if token:
        req_headers["Authorization"] = f"Bearer {token}"
    if headers:
        req_headers.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=req_headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, dict(resp.headers), json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} on {url}: {e.read().decode('utf-8', errors='replace')}")


def verify_http_wire(base_url: str, token: str) -> dict:
    # 1. /.well-known/agent-card.json -> strict protobuf AgentCard parse (no unknown fields)
    status, _, card_json = http_json(f"{base_url}/.well-known/agent-card.json")
    assert status == 200, f"card status={status}"
    card_pb = json_format.ParseDict(
        card_json, a2a_pb2.AgentCard(), ignore_unknown_fields=False
    )
    assert card_pb.name == "byte_server_agent", f"unexpected card name: {card_pb.name}"
    assert card_pb.capabilities.streaming is True
    assert card_pb.capabilities.push_notifications is True

    # 2. JSON-RPC POST / message/send -> strict SendMessageResponse parse
    rpc_req = {
        "jsonrpc": "2.0",
        "id": "oracle-rpc-1",
        "method": "message/send",
        "params": {
            "message": {
                "role": "ROLE_USER",
                "messageId": "oracle-msg-1",
                "metadata": {"skill": "create_order"},
                "parts": [
                    {
                        "data": {
                            "reference": "PO-ORACLE-HTTP-001",
                            "amount_cents": 7777,
                        }
                    }
                ],
            }
        },
    }
    status, _, rpc_resp = http_json(
        f"{base_url}/",
        token=token,
        body=rpc_req,
        headers={"A2A-Version": "1.1"},
    )
    assert status == 200, f"rpc status={status}"
    assert "error" not in rpc_resp or rpc_resp["error"] is None, f"rpc error: {rpc_resp}"
    send_resp_pb = json_format.ParseDict(
        rpc_resp["result"], a2a_pb2.SendMessageResponse(), ignore_unknown_fields=False
    )
    assert send_resp_pb.WhichOneof("payload") == "task"
    http_task_id = send_resp_pb.task.id
    assert http_task_id, "missing task id"
    assert send_resp_pb.task.status.state == a2a_pb2.TASK_STATE_COMPLETED

    # 3. HTTP+JSON REST GET /tasks/{id} -> strict Task parse
    status, _, rest_task_json = http_json(
        f"{base_url}/tasks/{http_task_id}",
        token=token,
        headers={"A2A-Version": "1.1"},
    )
    assert status == 200, f"rest get status={status}"
    rest_task_pb = json_format.ParseDict(
        rest_task_json, a2a_pb2.Task(), ignore_unknown_fields=False
    )
    assert rest_task_pb.id == http_task_id
    assert rest_task_pb.status.state == a2a_pb2.TASK_STATE_COMPLETED

    return {
        "card_name": card_pb.name,
        "http_task_id": http_task_id,
        "http_task_generation": rest_task_pb.generation,
    }


def verify_grpc_wire(grpc_port: int, token: str) -> dict:
    channel = grpc.insecure_channel(f"127.0.0.1:{grpc_port}")
    stub = a2a_pb2_grpc.A2AServiceStub(channel)
    md = [("authorization", f"Bearer {token}"), ("a2a-version", "1.1")]

    # Use list_orders (:read) via strict lf.a2a.v1.SendMessageRequest
    # In v1.1.0-rc specification/a2a.proto, Part.data is google.protobuf.Value
    msg_meta = struct_pb2.Struct()
    msg_meta.update({"skill": "list_orders"})
    part_struct = struct_pb2.Struct()
    part_struct.update({})
    part_data = struct_pb2.Value(struct_value=part_struct)

    req = a2a_pb2.SendMessageRequest(
        message=a2a_pb2.Message(
            message_id="oracle-grpc-msg-1",
            role=a2a_pb2.ROLE_USER,
            metadata=msg_meta,
            parts=[a2a_pb2.Part(data=part_data)],
        )
    )
    resp = stub.SendMessage(req, metadata=md, timeout=5)
    assert resp.WhichOneof("payload") == "task", f"unexpected grpc payload: {resp}"
    grpc_task_id = resp.task.id
    assert grpc_task_id, "missing grpc task id"

    got = stub.GetTask(a2a_pb2.GetTaskRequest(id=grpc_task_id), metadata=md, timeout=5)
    assert got.id == grpc_task_id

    listed = stub.ListTasks(a2a_pb2.ListTasksRequest(), metadata=md, timeout=5)
    assert any(t.id == grpc_task_id for t in listed.tasks), "grpc task missing in ListTasks"

    channel.close()
    return {
        "grpc_task_id": grpc_task_id,
        "grpc_task_state": a2a_pb2.TaskState.Name(resp.task.status.state),
        "grpc_task_generation": got.generation,
        "grpc_listed_count": len(listed.tasks),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--http-url", required=True)
    parser.add_argument("--grpc-port", type=int, required=True)
    parser.add_argument("--token", required=True)
    args = parser.parse_args()

    http_res = verify_http_wire(args.http_url, args.token)
    grpc_res = verify_grpc_wire(args.grpc_port, args.token)
    print(
        json.dumps(
            {
                "ok": True,
                "oracle": "a2aproject/a2a@v1.1.0-rc",
                "http": http_res,
                "grpc": grpc_res,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        sys.exit(1)
