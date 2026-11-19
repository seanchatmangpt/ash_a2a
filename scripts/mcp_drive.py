#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""Drive the ash_a2a simulation server through MCP, as a real MCP client.

Launches bin/a2a-sim-mcp (MCP over stdio), runs initialize and tools/list,
then runs the coverage plan the server publishes: for every item of the served
surface (JSON-RPC methods and aliases, HTTP+JSON routes, gRPC RPCs, skills,
consequence classes, task states, the security scheme, the mounts) it calls the
mapped tools through tools/call and checks what came back.

    python3 scripts/mcp_drive.py                  # the whole surface, one row per item
    python3 scripts/mcp_drive.py --only grpc_rpc: # items whose id starts with a prefix
    python3 scripts/mcp_drive.py --steps          # also print every tool call
    python3 scripts/mcp_drive.py --list           # the tool catalog
    python3 scripts/mcp_drive.py --call a2a_send_message '{"binding":"grpc","skill":"count_notes"}'
    python3 scripts/mcp_drive.py --read sim://surface

Exit status: 0 when every item passed, 1 on any failure, any surface item with
no plan, or any tool result that does not match its outputSchema.

Standard library only.
"""

import argparse
import json
import os
import queue
import random
import re
import string
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOCOL_VERSION = "2025-11-25"
MISSING = object()


class McpError(Exception):
    pass


class McpClient:
    """A minimal MCP stdio client: newline-delimited JSON-RPC 2.0."""

    def __init__(self, command, log_path):
        self.log_path = log_path
        self.log = open(log_path, "ab")
        self.proc = subprocess.Popen(
            command, cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log
        )
        self.inbox = queue.Queue()
        self.next_id = 0
        self.stray = []
        self.notifications = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                self.inbox.put(json.loads(line))
            except ValueError:
                # Anything on stdout that is not JSON breaks the transport.
                self.stray.append(line)
        self.inbox.put(None)

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def request(self, method, params=None, timeout=180.0):
        self.next_id += 1
        ident = self.next_id
        message = {"jsonrpc": "2.0", "id": ident, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        deadline = time.time() + timeout
        while True:
            try:
                reply = self.inbox.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                raise McpError("no reply to %s within %.0f s (server log: %s)" % (method, timeout, self.log_path))
            if reply is None:
                raise McpError("the server closed its stdout (server log: %s)" % self.log_path)
            if reply.get("id") == ident and ("result" in reply or "error" in reply):
                if "error" in reply:
                    raise McpError("%s answered JSON-RPC error %s" % (method, json.dumps(reply["error"])))
                return reply["result"]
            if "method" in reply and "id" not in reply:
                self.notifications.append(reply)

    def call(self, tool, arguments, progress=False):
        params = {"name": tool, "arguments": arguments}
        if progress:
            params["_meta"] = {"progressToken": "drive-%d" % (self.next_id + 1)}
        return self.request("tools/call", params)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()
        self.log.close()


# -- the plan interpreter -------------------------------------------------------


def substitute(value, variables):
    if isinstance(value, str):
        whole = re.fullmatch(r"\{\{(\w+)\}\}", value)
        if whole and whole.group(1) in variables:
            return variables[whole.group(1)]
        return re.sub(r"\{\{(\w+)\}\}", lambda m: str(variables.get(m.group(1), m.group(0))), value)
    if isinstance(value, list):
        return [substitute(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, variables) for key, item in value.items()}
    return value


def lookup(value, path):
    for segment in path.split("."):
        if isinstance(value, dict):
            if segment not in value:
                return MISSING
            value = value[segment]
        elif isinstance(value, list):
            try:
                value = value[int(segment)]
            except (ValueError, IndexError):
                return MISSING
        else:
            return MISSING
    return value


def as_text(value):
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def show(value, limit=160):
    text = "<absent>" if value is MISSING else json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "..."


def holds(actual, op, expected):
    present = actual is not MISSING and actual is not None
    plain = None if actual is MISSING else actual
    if op == "eq":
        return plain == expected
    if op == "ne":
        return plain != expected
    if op == "in":
        return plain in expected
    if op == "contains":
        return present and str(expected) in as_text(actual)
    if op == "not_contains":
        return not present or str(expected) not in as_text(actual)
    if op == "exists":
        return present
    if op == "absent":
        return not present
    if op == "gte":
        return isinstance(plain, (int, float)) and not isinstance(plain, bool) and plain >= expected
    raise McpError("the plan uses an operator this driver does not know: %r" % op)


def schema_errors(schema, value, path="result"):
    """The subset of JSON Schema the catalog's outputSchemas use."""
    errors = []
    kinds = schema.get("type")
    if kinds is not None:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        checks = {
            "object": lambda v: isinstance(v, dict),
            "array": lambda v: isinstance(v, list),
            "string": lambda v: isinstance(v, str),
            "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
            "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
            "boolean": lambda v: isinstance(v, bool),
            "null": lambda v: v is None,
        }
        if not any(checks[kind](value) for kind in kinds):
            errors.append("%s is not %s" % (path, " or ".join(kinds)))
            return errors
    if "enum" in schema and value not in schema["enum"]:
        errors.append("%s is not one of %s" % (path, schema["enum"]))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append("%s.%s is required" % (path, key))
        extra = schema.get("additionalProperties")
        for key, item in value.items():
            sub = schema.get("properties", {}).get(key)
            if sub is None and isinstance(extra, dict):
                sub = extra
            if sub is not None:
                errors.extend(schema_errors(sub, item, "%s.%s" % (path, key)))
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for index, item in enumerate(value):
            errors.extend(schema_errors(schema["items"], item, "%s[%d]" % (path, index)))
    return errors


class Driver:
    def __init__(self, client, tools, verbose):
        self.client = client
        self.tools = {tool["name"]: tool for tool in tools}
        self.verbose = verbose
        self.calls = 0
        self.schema_failures = []

    def tool(self, name, arguments):
        """One tools/call. Returns (structured, error_text)."""
        if name not in self.tools:
            return None, "the server lists no tool named %s" % name
        self.calls += 1
        result = self.client.call(name, arguments)
        if result.get("isError"):
            text = " ".join(part.get("text", "") for part in result.get("content", []))
            return None, "tool error: %s" % text
        structured = result.get("structuredContent")
        if not isinstance(structured, dict):
            return None, "the result has no structuredContent"
        text = "".join(part.get("text", "") for part in result.get("content", []) if part.get("type") == "text")
        if json.loads(text) != structured:
            return None, "content text and structuredContent differ"
        problems = schema_errors(self.tools[name].get("outputSchema", {}), structured)
        if problems:
            self.schema_failures.append((name, problems))
            return structured, "result does not match outputSchema: %s" % "; ".join(problems[:3])
        return structured, None

    def step(self, step, variables):
        """Runs one step. Returns (ok, detail)."""
        arguments = substitute(step["arguments"], variables)
        deadline = time.time() + step.get("retry_ms", 0) / 1000.0
        while True:
            structured, problem = self.tool(step["tool"], arguments)
            if problem is None:
                for expectation in step.get("expect", []):
                    wanted = substitute(expectation.get("value"), variables)
                    actual = lookup(structured, expectation["path"])
                    if not holds(actual, expectation["op"], wanted):
                        problem = "%s: expected %s %s, got %s" % (
                            expectation["path"],
                            expectation["op"],
                            show(wanted, 80),
                            show(actual),
                        )
                        break
            if problem is None or time.time() >= deadline:
                break
            time.sleep(0.1)
        if problem is not None:
            return False, problem
        for name, path in step.get("capture", {}).items():
            value = lookup(structured, path)
            if value is MISSING or value is None:
                return False, "nothing to capture at %s" % path
            variables[name] = value
        return True, summarize(structured)

    def entry(self, entry, info):
        """Runs one surface item's plan. Returns (ok, detail, step_rows)."""
        variables = dict(info)
        variables["uniq"] = "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(10))
        steps = entry.get("steps", [])
        if not steps or not any(step.get("tested") for step in steps):
            return False, "the plan has no step that reaches this item", []
        failure = None
        tested_detail = ""
        rows = []
        for index, step in enumerate(steps, 1):
            if failure and not step.get("always"):
                rows.append(("skip", index, step, "not run: an earlier step failed"))
                continue
            try:
                ok, detail = self.step(step, variables)
            except McpError as error:
                ok, detail = False, str(error)
            rows.append(("pass" if ok else "FAIL", index, step, detail))
            if ok and step.get("tested"):
                tested_detail = detail
            if not ok and failure is None:
                failure = "step %d/%d (%s) %s" % (index, len(steps), step["label"], detail)
        if failure:
            return False, failure, rows
        return True, "%d/%d steps; %s" % (len(steps), len(steps), tested_detail), rows


def summarize(structured):
    if "binding" in structured and "status" in structured:
        parts = [str(structured.get("status_name") or structured.get("status"))]
        if structured.get("final_state"):
            parts.append(structured["final_state"])
        if structured.get("frames"):
            parts.append("%d frames" % len(structured["frames"]))
        error = structured.get("error")
        if isinstance(error, dict) and "code" in error:
            parts.append("error %s" % error["code"])
        body = structured.get("body")
        if body is not None:
            parts.append("%d body bytes" % len(body.encode("utf-8")))
        return ", ".join(parts)
    if "verdicts" in structured:
        if not structured.get("ran"):
            return "not run: %s" % structured.get("reason")
        summary = structured["summary"]
        verdicts = ", ".join("%s %s" % (v["binding"], v["verdict"]) for v in structured["verdicts"])
        return "%s; %d rows pass, %d fail, %d known %s" % (
            verdicts,
            summary["pass"],
            summary["fail"],
            summary["known"],
            structured["known_defects"],
        )
    if "rows" in structured and "count" in structured:
        return "%d row(s)" % structured["count"]
    if "deliveries" in structured:
        return "%d delivery(ies)" % structured["count"]
    if "grants" in structured:
        return ", ".join("%s %s" % (g["skill"], g.get("outcome", g["granted"])) for g in structured["grants"])
    return "ok"


def table(rows, header):
    widths = [max(len(str(row[i])) for row in [header] + rows) for i in range(len(header) - 1)]
    lines = []
    for row in [header] + rows:
        cells = [str(cell).ljust(width) for cell, width in zip(row, widths)]
        lines.append(("  ".join(cells) + "  " + str(row[-1])).rstrip())
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="print the tool catalog and exit")
    parser.add_argument("--call", nargs=2, metavar=("TOOL", "JSON_ARGS"), help="call one tool and print its result")
    parser.add_argument("--read", metavar="URI", help="read one resource and print it")
    parser.add_argument("--only", metavar="PREFIX", help="run only surface items whose id starts with PREFIX")
    parser.add_argument("--steps", action="store_true", help="print every tool call of every item")
    parser.add_argument("--json", action="store_true", help="print the matrix as JSON")
    parser.add_argument("--server", "--launcher", dest="server", metavar="PATH", default=os.path.join(ROOT, "bin", "a2a-sim-mcp"), help="the MCP server command")
    parser.add_argument("--log", help="where the server's stderr goes (default: a temp file)")
    args = parser.parse_args()

    # This client does not act on notifications/tools/list_changed, so with no
    # shim cache it must be given the real catalog: let the launcher wait.
    os.environ.setdefault("A2A_SIM_MCP_INIT_WAIT", "900")
    os.environ.setdefault("A2A_SIM_MCP_LIST_WAIT", "900")
    log_path = args.log or os.path.join(tempfile.gettempdir(), "a2a-sim-mcp-%d.log" % os.getpid())
    client = McpClient([args.server], log_path)
    quiet = args.json
    say = (lambda *a, **k: None) if quiet else print

    try:
        started = time.time()
        init = client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mcp_drive.py", "version": "1"},
            },
        )
        client.notify("notifications/initialized")
        client.request("ping")
        tools = client.request("tools/list")["tools"]
        resources = client.request("resources/list")["resources"]

        if init["protocolVersion"] != PROTOCOL_VERSION:
            raise McpError("asked for MCP %s, the server negotiated %s" % (PROTOCOL_VERSION, init["protocolVersion"]))

        if args.list:
            print(table([[t["name"], t.get("title", ""), ""] for t in tools], ["TOOL", "TITLE", ""]))
            print("\n%d tools, %d resources: %s" % (len(tools), len(resources), ", ".join(r["uri"] for r in resources)))
            return 0

        if args.call:
            result = client.call(args.call[0], json.loads(args.call[1]), progress=True)
            for note in client.notifications:
                print("progress %s: %s" % (note["params"].get("progress"), note["params"].get("message")), file=sys.stderr)
            if result.get("isError"):
                print("".join(part.get("text", "") for part in result.get("content", [])), file=sys.stderr)
                return 1
            print(json.dumps(result.get("structuredContent"), indent=2, ensure_ascii=False))
            return 0

        if args.read:
            for content in client.request("resources/read", {"uri": args.read})["contents"]:
                print(content.get("text", ""))
            return 0

        say(
            "MCP %s  server %s %s  %d tools  %d resources  (ready in %.1f s)"
            % (
                init["protocolVersion"],
                init["serverInfo"]["name"],
                init["serverInfo"]["version"],
                len(tools),
                len(resources),
                time.time() - started,
            )
        )

        driver = Driver(client, tools, args.steps)
        info, problem = driver.tool("sim_info", {})
        if problem:
            raise McpError("sim_info: " + problem)
        surface, problem = driver.tool("sim_surface", {})
        if problem:
            raise McpError("sim_surface: " + problem)
        plan = json.loads(client.request("resources/read", {"uri": "sim://coverage"})["contents"][0]["text"])
        say("A2A %s at %s  gRPC %s  push receiver %s" % (info.get("a2a_version"), info["base_url"], info["grpc_target"], info["push_url"]))
        say("")

        planned = {entry["surface"]: entry for entry in plan["items"]}
        surface_ids = [item["id"] for item in surface["items"]]
        results = []
        for surface_id in surface_ids:
            if args.only and not surface_id.startswith(args.only):
                continue
            entry = planned.get(surface_id)
            if entry is None:
                results.append({"surface": surface_id, "tool": "-", "binding": "-", "status": "FAIL", "detail": "no coverage plan: MCP cannot reach this item", "steps": []})
                continue
            ok, detail, rows = driver.entry(entry, info)
            results.append(
                {
                    "surface": surface_id,
                    "tool": entry.get("tool") or "-",
                    "binding": entry.get("binding") or "-",
                    "status": "pass" if ok else "FAIL",
                    "detail": detail,
                    "steps": [
                        {"n": n, "status": status, "label": step["label"], "tool": step["tool"], "detail": text}
                        for status, n, step, text in rows
                    ],
                }
            )
            if not quiet and args.steps:
                last = results[-1]
                print("%s  %s" % (last["status"], last["surface"]))
                for row in last["steps"]:
                    print("    %-4s %d. %s  [%s]  %s" % (row["status"], row["n"], row["label"], row["tool"], row["detail"]))

        failed = [r for r in results if r["status"] != "pass"]
        uncovered = plan.get("uncovered", []) + surface.get("uncovered", [])
        stray = client.stray

        if args.json:
            print(json.dumps({"results": results, "uncovered": sorted(set(uncovered)), "calls": driver.calls}, indent=2))
        else:
            if not args.steps:
                print(
                    table(
                        [[r["surface"], r["tool"], r["binding"], r["status"], r["detail"]] for r in results],
                        ["SURFACE", "TOOL", "BINDING", "STATUS", "DETAIL"],
                    )
                )
            print("")
            for surface_id in sorted(set(uncovered)):
                print("UNCOVERED  %s has no MCP tool path" % surface_id)
            for name, problems in driver.schema_failures:
                print("SCHEMA  %s: %s" % (name, "; ".join(problems[:3])))
            for line in stray[:5]:
                print("STDOUT NOISE  %s" % line[:200])
            print(
                "%d surface items served, %d driven through MCP: %d pass, %d fail; %d uncovered; "
                "%d tools/call requests; %d outputSchema violations; %d non-MCP lines on stdout"
                % (
                    len(surface_ids),
                    len(results),
                    len(results) - len(failed),
                    len(failed),
                    len(set(uncovered)),
                    driver.calls,
                    len(driver.schema_failures),
                    len(stray),
                )
            )
            if failed or stray:
                print("server log: %s" % log_path)

        return 1 if failed or uncovered or driver.schema_failures or stray else 0
    except McpError as error:
        print("mcp_drive: %s" % error, file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
