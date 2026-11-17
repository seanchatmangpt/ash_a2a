#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
"""Copy the JSON document out of a mix task's stdout.

`mix ash_a2a.sim --prove --json` prints the report on stdout, but the test
environment's Logger also writes boot warnings there first. This reads stdin,
takes the first line that is exactly `{` (the pretty-printed document start),
decodes everything from there, and writes it to the path given as argv[1].
Exit 1 when there is no document or it does not decode, so a truncated report
fails the step instead of uploading garbage.

    mix ash_a2a.sim --prove --json | python3 -I scripts/ci_extract_json.py out.json
"""
import json
import sys


def main(argv):
    if len(argv) != 2:
        print("usage: ci_extract_json.py OUT.json", file=sys.stderr)
        return 2
    text = sys.stdin.read()
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.rstrip("\r\n") == "{"), None)
    if start is None:
        print("ci_extract_json: no JSON document on stdin", file=sys.stderr)
        return 1
    try:
        doc, _end = json.JSONDecoder().raw_decode("".join(lines[start:]))
    except ValueError as err:
        print("ci_extract_json: JSON does not decode: %s" % err, file=sys.stderr)
        return 1
    with open(argv[1], "w", encoding="utf-8") as out:
        json.dump(doc, out, indent=2)
        out.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
