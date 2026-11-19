#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT
"""Assert a2a-tck compatibility.json has no failed MUST requirement.

Usage: scripts/tck_assert.py PATH [--expected-failures FILE] [--tck-sha SHA]

The real compatibility.json schema is not pinned by this repo, so the
reader is tolerant. It looks for requirement records (any JSON object that
carries a status-like string) anywhere in the document and, only when none
exist, for aggregate count objects (e.g. {"PASS": 3, "FAILED": 0}).

Rules (fail closed):
  * a failed requirement whose level is MUST -- or whose level cannot be
    determined -- is a failure (exit 1);
  * a document with no recognizable records or counts is a failure (exit 2);
  * a missing/unreadable file is a failure (exit 2);
  * not_tested and manual are counted and printed, never silently dropped.

Expected failures (scripts/tck_expected_failures.json, optional):
  * only ids LISTED in the file are tolerated, and only while they still
    fail: a listed id that passes (or is absent / not failing) is a failure
    (exit 1) so the list cannot rot;
  * with the file given, ANY unlisted failed requirement (any level) is a
    failure (exit 1);
  * an entry may carry "tck_commits" (full or abbreviated SHAs); with
    --tck-sha it applies only to those TCK commits, otherwise it is ignored
    (the failure is then judged by the normal rules);
  * an unreadable or malformed expected-failures file exits 2.

Prints: pass=N fail=N not_tested=N skipped=N manual=N must_fail=N
"""
import json
import re
import sys

STATUS = {
    "PASS": "pass", "PASSED": "pass",
    "FAIL": "fail", "FAILED": "fail", "ERROR": "fail",
    "NOT_TESTED": "not_tested", "NOT_RUN": "not_tested", "UNTESTED": "not_tested",
    "SKIP": "skipped", "SKIPPED": "skipped",
    "MANUAL": "manual",
}
BUCKETS = ("pass", "fail", "not_tested", "skipped", "manual")
STATUS_KEYS = ("status", "result", "outcome", "verdict")
LEVEL_KEYS = ("level", "requirement_level", "category", "severity")


def norm_status(value):
    if not isinstance(value, str):
        return None
    return STATUS.get(value.strip().upper().replace(" ", "_").replace("-", "_"))


def level_of(text):
    t = str(text).lower()
    for name in ("must", "should", "may"):
        if name in t:
            return name
    return None


ID_RE = re.compile(r"^[A-Z][A-Z0-9_]*(-[A-Z0-9_]+)+$")


def find_records(node, hint, out, key=None):
    """Collect (bucket, level, id) for every status-bearing object.

    The id is the object's own "id" field, else the dict key it sits under
    when that key looks like a requirement id (e.g. "HTTP_JSON-SVC-001").
    """
    found = False
    if isinstance(node, dict):
        bucket = None
        for k in STATUS_KEYS:
            bucket = norm_status(node.get(k))
            if bucket:
                break
        own = None
        for k in LEVEL_KEYS:
            if k in node:
                own = level_of(node[k]) or own
        if bucket:
            rid = node.get("id") if isinstance(node.get("id"), str) else None
            if rid is None and isinstance(key, str) and ID_RE.match(key):
                rid = key
            out.append((bucket, own or hint, rid))
            return True
        for k, child in node.items():
            if find_records(child, level_of(k) or hint, out, k):
                found = True
    elif isinstance(node, list):
        for child in node:
            if find_records(child, hint, out, key):
                found = True
    return found


def find_counts(node, hint, out):
    """Collect aggregate count objects, outermost first, no double counting."""
    if isinstance(node, dict):
        counts = {}
        for key, val in node.items():
            bucket = norm_status(key)
            if bucket and isinstance(val, int) and not isinstance(val, bool):
                counts[bucket] = counts.get(bucket, 0) + val
        if counts:
            out.append((counts, hint))
            return
        for key, child in node.items():
            find_counts(child, level_of(key) or hint, out)
    elif isinstance(node, list):
        for child in node:
            find_counts(child, hint, out)


def load_expected(path, tck_sha):
    """Return {id: entry} of expected failures applicable to tck_sha."""
    try:
        with open(path) as fh:
            doc = json.load(fh)
        entries = doc["expected_failures"]
        out = {}
        for e in entries:
            rid = e["id"]
            for field in ("reason", "contradicts", "spec_section"):
                if not isinstance(e.get(field), str) or not e[field].strip():
                    raise ValueError(f"{rid}: missing '{field}'")
            commits = e.get("tck_commits")
            if tck_sha and commits and not any(
                    tck_sha.startswith(c) or c.startswith(tck_sha)
                    for c in commits):
                continue
            out[rid] = e
        return out
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FATAL: cannot use expected-failures {path}: {exc!r}",
              file=sys.stderr)
        return None


def main(argv):
    args = argv[1:]
    expected_path = tck_sha = None
    rest = []
    while args:
        a = args.pop(0)
        if a in ("--expected-failures", "--tck-sha"):
            if not args:
                print(f"usage: {a} needs a value", file=sys.stderr)
                return 2
            if a == "--tck-sha":
                tck_sha = args.pop(0)
            else:
                expected_path = args.pop(0)
        else:
            rest.append(a)
    if len(rest) != 1:
        print("usage: tck_assert.py PATH [--expected-failures FILE] "
              "[--tck-sha SHA]", file=sys.stderr)
        return 2
    path = rest[0]
    expected = None
    if expected_path is not None:
        expected = load_expected(expected_path, tck_sha)
        if expected is None:
            return 2
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"FATAL: cannot read {path}: {exc}", file=sys.stderr)
        return 2

    totals = {b: 0 for b in BUCKETS}
    must_fail = 0
    unexpected = []
    seen_expected = {}

    records = []
    find_records(data, None, records)
    if records:
        for bucket, level, rid in records:
            totals[bucket] += 1
            if expected is not None:
                if rid in expected:
                    seen_expected.setdefault(rid, set()).add(bucket)
                if bucket == "fail" and rid not in expected:
                    unexpected.append(rid or "<no id>")
                    if level in (None, "must"):
                        must_fail += 1
            elif bucket == "fail" and level in (None, "must"):
                must_fail += 1
    else:
        if expected:
            print("FATAL: expected-failures given but the report has no "
                  "per-requirement records", file=sys.stderr)
            return 2
        aggregates = []
        find_counts(data, None, aggregates)
        if not aggregates:
            print(f"FATAL: {path}: no requirement records or counts recognized",
                  file=sys.stderr)
            return 2
        for counts, level in aggregates:
            for bucket, n in counts.items():
                totals[bucket] += n
            if counts.get("fail", 0) and level in (None, "must"):
                must_fail += counts["fail"]

    expected_fail = 0
    rotted = []
    if expected:
        for rid in sorted(expected):
            if "fail" in seen_expected.get(rid, set()):
                expected_fail += 1
            else:
                rotted.append((rid, sorted(seen_expected.get(rid, {"absent"}))))
    line = ("pass={pass} fail={fail} not_tested={not_tested} skipped={skipped} "
            "manual={manual}".format(**totals) + f" must_fail={must_fail}")
    if expected is not None:
        line += (f" expected_fail={expected_fail}"
                 f" unexpected_fail={len(unexpected)}")
    print(line)
    status = 0
    for rid in unexpected:
        print(f"TCK: unexpected failure {rid} (not in expected-failures)",
              file=sys.stderr)
        status = 1
    for rid, states in rotted:
        print(f"TCK: expected failure {rid} no longer fails (status: "
              f"{','.join(states)}); remove it from the expected-failures list",
              file=sys.stderr)
        status = 1
    if status:
        return status
    if must_fail:
        print(f"TCK: {must_fail} failed MUST requirement(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
