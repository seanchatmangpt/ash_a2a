#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT
"""Assert a2a-tck compatibility.json has no failed MUST requirement.

Usage: scripts/tck_assert.py PATH [--strict-level]

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

Prints: pass=N fail=N not_tested=N skipped=N manual=N must_fail=N
"""
import json
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


def find_records(node, hint, out):
    """Collect (bucket, level) for every status-bearing object."""
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
            out.append((bucket, own or hint))
            return True
        for key, child in node.items():
            if find_records(child, level_of(key) or hint, out):
                found = True
    elif isinstance(node, list):
        for child in node:
            if find_records(child, hint, out):
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


def main(argv):
    if len(argv) < 2:
        print("usage: tck_assert.py PATH", file=sys.stderr)
        return 2
    path = argv[1]
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"FATAL: cannot read {path}: {exc}", file=sys.stderr)
        return 2

    totals = {b: 0 for b in BUCKETS}
    must_fail = 0

    records = []
    find_records(data, None, records)
    if records:
        for bucket, level in records:
            totals[bucket] += 1
            if bucket == "fail" and level in (None, "must"):
                must_fail += 1
    else:
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

    print("pass={pass} fail={fail} not_tested={not_tested} skipped={skipped} "
          "manual={manual}".format(**totals) + f" must_fail={must_fail}")
    if must_fail:
        print(f"TCK: {must_fail} failed MUST requirement(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
