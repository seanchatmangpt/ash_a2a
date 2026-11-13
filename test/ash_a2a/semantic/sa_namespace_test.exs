defmodule AshA2A.Semantic.SaNamespaceTest do
  use ExUnit.Case, async: true

  alias AshA2A.Semantic.{FalsifierSuite, Vocabulary}

  test "falsifier suite uses the single Vocabulary sa: namespace" do
    assert FalsifierSuite.namespace() == Vocabulary.sa_namespace()
    assert FalsifierSuite.sa("X") == Vocabulary.sa_namespace() <> "X"
    {:ok, ask} = FalsifierSuite.ask(:do_without_prepared_receipt)
    assert ask =~ "PREFIX sa: <#{Vocabulary.sa_namespace()}>"
  end

  test "to_ntriples escapes IRIs and literals via Serialize" do
    graph = [
      {"http://e/a b>", "http://e/p", {:lit, "line\n\"q\"\\"}},
      {"http://e/s", "http://e/p", "http://e/o"}
    ]

    nt = FalsifierSuite.to_ntriples(graph)
    assert nt =~ "<http://e/a\\u0020b\\u003E> <http://e/p> \"line\\n\\\"q\\\"\\\\\" ."
    assert nt =~ "<http://e/s> <http://e/p> <http://e/o> ."
    refute nt =~ "a b"
  end
end
