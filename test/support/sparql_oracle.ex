defmodule AshA2A.SparqlOracle do
  @moduledoc """
  Runs a real, independent SPARQL 1.1 engine over fixture graphs.

  This is a real collaborator, not a test double: it writes the fixtures to
  real files on disk, launches a real OS process, and returns the real
  booleans that engine computed. Nothing here fakes an interaction.

  Its only purpose is to execute the **normative** `ASK` text carried by each
  `AshA2A.Semantic.Falsifier`, so that
  `AshA2A.Semantic.FalsifierSuite.evaluate/2`'s structural evaluator can be
  held to agreement with a genuine SPARQL implementation of the same query
  rather than merely asserted to correspond to one.

  `available?/0` reports whether the engine is reachable on this machine. The
  oracle test uses it to skip with a **named, visible reason** rather than
  silently substituting a fake -- a machine without the engine gets a skip
  that says so, never a green test that proved nothing.

  `ask_many/1` batches every pair into a single engine process. That is not
  an optimisation detail: the conformance cross-product is 14 normative
  queries against 28 fixture graphs, and paying interpreter startup 392 times
  took longer than ExUnit's per-test timeout while the queries themselves
  take milliseconds. `ask/2` is the one-pair case of the same code path, so
  there is no second implementation to drift.
  """

  @script Path.join(__DIR__, "sparql_oracle.py")

  @doc "Absolute path of the oracle script."
  def script, do: @script

  @doc """
  Whether a real SPARQL engine is reachable here.

  Returns `{:ok, version}` or `{:error, reason}` -- the reason is surfaced in
  the skip message so an absent oracle is always explained.
  """
  @spec available?() :: {:ok, binary()} | {:error, binary()}
  def available? do
    case System.cmd("python3", ["-c", "import rdflib; print(rdflib.__version__)"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, "rdflib " <> String.trim(out)}
      {out, code} -> {:error, "python3 exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "python3 not executable: #{inspect(e.original)}"}
  end

  @doc """
  Execute one SPARQL 1.1 `ASK` against one graph, returning the real boolean
  the engine computed.
  """
  @spec ask([tuple()], binary()) :: {:ok, boolean()} | {:error, binary()}
  def ask(graph, query) when is_list(graph) and is_binary(query) do
    case ask_many([{graph, query}]) do
      {:ok, [result]} -> {:ok, result}
      {:ok, other} -> {:error, "expected one result, got #{length(other)}"}
      {:error, _} = error -> error
    end
  end

  @doc """
  Execute many `{graph, ask_query}` pairs in a single engine process.

  Returns `{:ok, [boolean]}` in the same order as `pairs`, or `{:error,
  reason}` carrying the engine's own stderr so a malformed normative query
  fails loudly rather than being read as `false`.
  """
  @spec ask_many([{[tuple()], binary()}]) :: {:ok, [boolean()]} | {:error, binary()}
  def ask_many([]), do: {:ok, []}

  def ask_many(pairs) when is_list(pairs) do
    # `System.unique_integer/1` is unique only within ONE VM; the OS pid makes
    # the directory unique across concurrent BEAMs sharing the same tmp dir
    # (a second `mix test` would otherwise collide on `sa2a-oracle-<n>` and
    # `rm_rf!` this run's files mid-flight: "missing query file for 00014.nt").
    dir =
      Path.join(
        System.tmp_dir!(),
        "sa2a-oracle-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    try do
      pairs
      |> Enum.with_index()
      |> Enum.each(fn {{graph, query}, index} ->
        stem = Path.join(dir, String.pad_leading(Integer.to_string(index), 5, "0"))
        File.write!(stem <> ".nt", AshA2A.Semantic.FalsifierSuite.to_ntriples(graph))
        File.write!(stem <> ".rq", query)
      end)

      case System.cmd("python3", [@script, dir], stderr_to_stdout: true) do
        {out, 0} -> decode(out, length(pairs))
        {out, code} -> {:error, "oracle exited #{code}: #{String.trim(out)}"}
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp decode(out, expected) do
    lines = out |> String.trim() |> String.split("\n", trim: true)

    cond do
      length(lines) != expected ->
        {:error, "expected #{expected} results, got #{length(lines)}: #{inspect(out)}"}

      Enum.all?(lines, &(&1 in ["true", "false"])) ->
        {:ok, Enum.map(lines, &(&1 == "true"))}

      true ->
        {:error, "unexpected oracle output: #{inspect(out)}"}
    end
  end
end
