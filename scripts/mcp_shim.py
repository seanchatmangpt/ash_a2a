#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""Launcher shim for the a2a-sim MCP server (Python 3 standard library only).

bin/a2a-sim-mcp starts this shim in stdio mode. MCP clients give up on a
server that does not answer `initialize` within a connect budget (30 s), and a
stale or cold Mix build takes longer than that to compile. The shim answers
the handshake at once and starts the real server in the background:

  * `initialize`, `ping`, `tools/list`, `resources/list` (and
    `resources/templates/list`) are answered immediately from a cache file
    written by the last healthy start (`$A2A_SIM_MCP_CACHE`, default
    `<MIX_BUILD_PATH or _build>/a2a_sim_mcp_cache.json`).
  * With no cache, `initialize` waits up to `A2A_SIM_MCP_INIT_WAIT` seconds
    (default 15) for the real server and then answers a minimal capabilities
    object; `tools/list` is an empty list until the server is up, and the shim
    then sends `notifications/tools/list_changed`. The shim therefore always
    declares `tools.listChanged: true`.
  * Any other request waits for the real server. If the server dies before it
    serves (for example a compile error) each waiting and later request is
    answered with a JSON-RPC error that quotes the failure, not left hanging.
  * Once the real server serves, every later message goes through byte for
    byte in both directions; ids are never rewritten. The shim performs its
    own handshake with the server (ids `a2a-shim-N`) and swallows the answers.

Logs go to standard error (or `A2A_SIM_MCP_LOG`, which bin/a2a-sim-mcp applies).
Standard output carries MCP frames only. Environment:

  A2A_SIM_MCP_BACKEND    the command that starts the real server (default
                         `bin/a2a-sim-mcp` with A2A_SIM_MCP_DIRECT=1)
  A2A_SIM_MCP_CACHE      cache file path
  A2A_SIM_MCP_INIT_WAIT  seconds `initialize` waits when there is no cache
"""

import collections
import json
import os
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOCOL_VERSION = "2025-11-25"
SHIM_PREFIX = "a2a-shim-"
LOCAL_METHODS = {"ping", "initialize", "tools/list", "resources/list", "resources/templates/list"}

out_lock = threading.Lock()
cond = threading.Condition()
state = {"phase": "starting", "failure": None}  # starting | ready | failed
tail = collections.deque(maxlen=60)
real_replies = {}
served_tools = None  # the list a client got before the real server was up
client_version = [PROTOCOL_VERSION]


def log(text):
    sys.stderr.write("[a2a-sim-mcp shim] %s\n" % text)
    sys.stderr.flush()


def emit_raw(raw):
    with out_lock:
        sys.stdout.buffer.write(raw if raw.endswith(b"\n") else raw + b"\n")
        sys.stdout.buffer.flush()


def emit(message):
    emit_raw(json.dumps(message, ensure_ascii=False).encode("utf-8"))


def reply(ident, result):
    emit({"jsonrpc": "2.0", "id": ident, "result": result})


def fail(ident, code, text):
    emit({"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": text}})


def cache_path():
    if os.environ.get("A2A_SIM_MCP_CACHE"):
        return os.environ["A2A_SIM_MCP_CACHE"]
    build = os.environ.get("MIX_BUILD_PATH") or os.path.join(ROOT, "_build")
    return os.path.join(build, "a2a_sim_mcp_cache.json")


def load_cache():
    try:
        with open(cache_path(), "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data.get("initialize"), dict) and isinstance(data.get("tools"), list):
            return data
    except (OSError, ValueError):
        pass
    return None


def save_cache(data):
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError as error:
        log("cannot write cache %s: %s" % (path, error))


def minimal_initialize(version):
    return {
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": True}, "resources": {"subscribe": False, "listChanged": False}},
        "serverInfo": {"name": "ash-a2a-sim-mcp", "title": "ash_a2a simulation server over MCP (starting)", "version": "0"},
    }


def with_list_changed(result):
    result = json.loads(json.dumps(result))
    caps = result.setdefault("capabilities", {})
    caps["tools"] = dict(caps.get("tools") or {}, listChanged=True)
    return result


backend = None
stderr_thread = [None]


def start_backend():
    global backend
    command = os.environ.get("A2A_SIM_MCP_BACKEND")
    argv = command.split() if command else [os.path.join(ROOT, "bin", "a2a-sim-mcp")]
    env = dict(os.environ, A2A_SIM_MCP_DIRECT="1")
    # bin/a2a-sim-mcp already pointed this process's stderr at the log; the
    # server's stderr must come through the pipe so failures can be quoted.
    env.pop("A2A_SIM_MCP_LOG", None)
    backend = subprocess.Popen(
        argv + sys.argv[1:], cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    stderr_thread[0] = threading.Thread(target=pump_stderr, daemon=True)
    stderr_thread[0].start()
    threading.Thread(target=backend_reader, daemon=True).start()


def pump_stderr():
    for raw in backend.stderr:
        text = raw.decode("utf-8", "replace").rstrip("\n")
        tail.append(text)
        sys.stderr.write(text + "\n")
        sys.stderr.flush()


def send_backend(message=None, raw=None):
    data = raw if raw is not None else json.dumps(message, ensure_ascii=False).encode("utf-8")
    try:
        backend.stdin.write(data if data.endswith(b"\n") else data + b"\n")
        backend.stdin.flush()
        return True
    except (OSError, ValueError):
        return False


def backend_request(method, params, ident, timeout=60.0):
    message = {"jsonrpc": "2.0", "id": SHIM_PREFIX + str(ident), "method": method}
    if params is not None:
        message["params"] = params
    if not send_backend(message):
        raise RuntimeError("the server closed its input")
    deadline = time.time() + timeout
    with cond:
        while message["id"] not in real_replies:
            if backend.poll() is not None and message["id"] not in real_replies:
                raise RuntimeError("the server exited")
            left = deadline - time.time()
            if left <= 0:
                raise RuntimeError("no answer to %s" % method)
            cond.wait(min(left, 0.5))
        return real_replies.pop(message["id"])


def paged(method, key, first_id):
    items, cursor, n = [], None, 0
    while True:
        n += 1
        got = backend_request(method, {"cursor": cursor} if cursor else {}, "%s%d" % (first_id, n))
        if "result" not in got:
            raise RuntimeError("%s failed: %s" % (method, got.get("error")))
        items.extend(got["result"].get(key, []))
        cursor = got["result"].get("nextCursor")
        if not cursor:
            return items


def backend_reader():
    for raw in backend.stdout:
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            message = json.loads(stripped)
        except ValueError:
            log("the server wrote non-JSON on its MCP channel: %r" % stripped[:200])
            continue
        ident = message.get("id") if isinstance(message, dict) else None
        if isinstance(ident, str) and ident.startswith(SHIM_PREFIX) and "method" not in message:
            with cond:
                real_replies[ident] = message
                cond.notify_all()
        elif state["phase"] == "ready":
            emit_raw(raw)
        # Frames before the handshake completes are not expected; drop them.
    with cond:
        if state["phase"] != "ready":
            code = backend.wait()
            stderr_thread[0].join(timeout=3)
            state["phase"] = "failed"
            state["failure"] = failure_text(code)
            log(state["failure"])
        cond.notify_all()
    if state["phase"] == "ready":
        log("the server exited (%s); shutting the shim down" % backend.poll())
        os._exit(backend.poll() or 0)


def failure_text(code):
    lines = [line for line in tail if line.strip()]
    errors = [i for i, line in enumerate(lines) if "error" in line.lower()]
    chosen = lines[max(0, errors[0] - 1) : errors[0] + 12] if errors else lines[-12:]
    return "the a2a-sim server did not start (mix exited with status %s). Compile output:\n%s" % (
        code,
        "\n".join(chosen) or "(no output; see the server log)",
    )


def handshake():
    """Initialize the real server, refresh the cache, tell the client what changed."""
    try:
        init = backend_request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "a2a-sim-mcp-shim", "version": "1"},
            },
            "init",
            timeout=1800,
        )
        if "result" not in init:
            raise RuntimeError("initialize failed: %s" % init.get("error"))
        send_backend({"jsonrpc": "2.0", "method": "notifications/initialized"})
        tools = paged("tools/list", "tools", "tools")
        resources = paged("resources/list", "resources", "resources")
        fresh = {"initialize": init["result"], "tools": tools, "resources": resources, "written_at": time.time()}
        with cond:
            state["live"] = fresh
            state["phase"] = "ready"
            cond.notify_all()
        save_cache(fresh)
        log("real server is serving (%d tools, %d resources)" % (len(tools), len(resources)))
        if served_tools is not None and served_tools != tools:
            emit({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
    except RuntimeError as error:
        with cond:
            if state["phase"] != "ready":
                code = backend.poll()
                if code is not None:
                    stderr_thread[0].join(timeout=3)
                state["phase"] = "failed"
                state["failure"] = failure_text(code) if code is not None else "the a2a-sim server did not become ready: %s" % error
                log(state["failure"])
            cond.notify_all()


def wait_ready(timeout):
    deadline = time.time() + timeout
    with cond:
        while state["phase"] == "starting":
            left = deadline - time.time()
            if left <= 0:
                break
            cond.wait(left)
        return state["phase"]


def handle_local(message, cache):
    global served_tools
    method, ident = message["method"], message["id"]
    if method == "ping":
        return reply(ident, {})
    live = state.get("live")
    if method == "initialize":
        params = message.get("params") or {}
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        if not isinstance(requested, str):
            return fail(ident, -32602, "initialize needs params.protocolVersion")
        if live is None and cache is None:
            wait_ready(float(os.environ.get("A2A_SIM_MCP_INIT_WAIT", "15")))
            live = state.get("live")
        source = (live or cache or {}).get("initialize") or minimal_initialize(PROTOCOL_VERSION)
        return reply(ident, with_list_changed(source))
    source = live or cache
    if method == "tools/list":
        tools = (source or {}).get("tools", [])
        if live is None:
            served_tools = tools
        return reply(ident, {"tools": tools})
    if method == "resources/list":
        return reply(ident, {"resources": (source or {}).get("resources", [])})
    return reply(ident, {"resourceTemplates": []})


def serve_after_ready(message, raw):
    """Run in a thread: wait for the real server, then forward or refuse."""
    phase = wait_ready(1800)
    ident = message.get("id")
    if phase == "ready":
        send_backend(raw=raw)
    elif ident is not None:
        fail(ident, -32603, state["failure"] or "the a2a-sim server is not available")


def main():
    cache = load_cache()
    log("cache %s: %s" % (cache_path(), "found" if cache else "none (answering a minimal handshake)"))
    start_backend()
    threading.Thread(target=handshake, daemon=True).start()

    for raw in sys.stdin.buffer:
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            message = json.loads(stripped)
        except ValueError:
            if state["phase"] == "ready":
                send_backend(raw=raw)
            else:
                fail(None, -32700, "the message is not JSON")
            continue
        method = message.get("method") if isinstance(message, dict) else None
        ident = message.get("id") if isinstance(message, dict) else None
        is_request = method is not None and "id" in message and isinstance(ident, (str, int)) and not isinstance(ident, bool)
        if method == "notifications/initialized":
            continue  # the shim sent its own to the real server
        if is_request and method in LOCAL_METHODS and (
            method in ("initialize", "ping") or state["phase"] != "ready"
        ):
            handle_local(message, cache)
        elif state["phase"] == "ready":
            send_backend(raw=raw)
        elif state["phase"] == "failed":
            if is_request:
                fail(ident, -32603, state["failure"])
        else:
            threading.Thread(target=serve_after_ready, args=(message, raw), daemon=True).start()

    # The client closed its end.
    try:
        backend.stdin.close()
    except OSError:
        pass
    try:
        backend.wait(timeout=10)
    except subprocess.TimeoutExpired:
        backend.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
