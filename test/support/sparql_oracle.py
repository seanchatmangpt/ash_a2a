"""Real SPARQL 1.1 ASK oracle for the RFC S61 falsifier conformance suite.

Executes one or more (N-Triples graph, SPARQL query) pairs with a real,
independent SPARQL 1.1 engine (rdflib) and prints `true` or `false` for each,
one per line, in index order.

This exists so `AshA2A.Semantic.FalsifierSuite`'s normative `ASK` text is
actually *executed* rather than merely documented. The Elixir structural
evaluator is asserted to agree with this engine's answer on every fixture.
An independent implementation is the point: if the structural evaluator and
this engine disagree, the structural evaluator is wrong about the normative
query, and the test says so.

Usage:

    sparql_oracle.py <dir>

`<dir>` contains `000.nt`/`000.rq`, `001.nt`/`001.rq`, ... One line of output
per pair. Batching many pairs into a single process matters: the conformance
cross-product is 14 queries x 28 fixture graphs, and paying interpreter
startup 392 times dominates the actual query evaluation by an order of
magnitude.

Parsed graphs are cached by content so a graph reused across the fourteen
queries is parsed once. The cache is keyed on the file's bytes, so two
distinct graphs can never collide onto one parse.

Exits non-zero with a message on stderr if a query is not an ASK or fails to
parse, so a malformed normative query is a loud failure and never a
silently-passing one.
"""

import pathlib
import sys

from rdflib import Graph


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: sparql_oracle.py <dir>", file=sys.stderr)
        return 2

    directory = pathlib.Path(sys.argv[1])
    graph_files = sorted(directory.glob("*.nt"))

    if not graph_files:
        print(f"no .nt files in {directory}", file=sys.stderr)
        return 2

    cache: dict[bytes, Graph] = {}
    out = []

    for graph_file in graph_files:
        query_file = graph_file.with_suffix(".rq")
        if not query_file.exists():
            print(f"missing query file for {graph_file.name}", file=sys.stderr)
            return 2

        raw = graph_file.read_bytes()
        graph = cache.get(raw)
        if graph is None:
            graph = Graph()
            graph.parse(data=raw.decode("utf-8"), format="nt")
            cache[raw] = graph

        result = graph.query(query_file.read_text(encoding="utf-8"))

        if result.askAnswer is None:
            print(f"{query_file.name} is not an ASK query", file=sys.stderr)
            return 3

        out.append("true" if result.askAnswer else "false")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
