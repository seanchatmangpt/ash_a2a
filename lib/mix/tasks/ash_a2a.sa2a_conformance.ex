defmodule Mix.Tasks.AshA2a.Sa2aConformance do
  @shortdoc "Runs the SA2A portable semantic execution conformance court"

  @moduledoc """
  Runs `AshA2A.SA2A.Conformance` over `priv/sa2a_conformance/` in two
  genuinely different WebAssembly runtimes and prints the machine-readable
  receipt.

      mix ash_a2a.sa2a_conformance
      mix ash_a2a.sa2a_conformance --out receipt.json
      mix ash_a2a.sa2a_conformance --wasm /path/to/praxis_graphlaw_wasm_bg.wasm

  ## Exit status

  Exits `0` only when all five assertions were computed and all five are
  true. Exits `1` on any false assertion, any assertion that could not be
  computed, and any failure to start the run at all. **An assertion that
  could not be computed is a failure, not a skip** -- an absent measurement
  is exactly the outcome a conformance court must never launder into a pass.

  ## Options

    * `--out PATH` -- also write the receipt JSON to `PATH`.
    * `--wasm PATH` -- GraphLaw wasm module to load in both runtimes.
    * `--corpus PATH` -- conformance corpus directory.
    * `--runtime-a MODULE` / `--runtime-b MODULE` -- override either runtime
      (Elixir module name, e.g. `AshA2A.GraphLaw.Wasm`). The court refuses a
      run whose two runtimes share a `{host_id, engine_id}` pair.
    * `--quiet` -- print only the receipt JSON, for piping into `jq`.
  """

  use Mix.Task

  alias AshA2A.SA2A.Conformance

  @switches [
    out: :string,
    wasm: :string,
    corpus: :string,
    runtime_a: :string,
    runtime_b: :string,
    quiet: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    run_opts =
      []
      |> put_if(opts[:wasm], :wasm_path)
      |> put_if(opts[:corpus], :corpus_dir)
      |> put_module(opts[:runtime_a], :runtime_a)
      |> put_module(opts[:runtime_b], :runtime_b)

    quiet? = opts[:quiet] == true

    case Conformance.run(run_opts) do
      {:ok, receipt} ->
        emit(receipt, opts[:out], quiet?)
        unless quiet?, do: summarise(receipt, "PASS")

      {:error, %{"profile" => _} = receipt} ->
        emit(receipt, opts[:out], quiet?)
        unless quiet?, do: summarise(receipt, "FAIL")
        exit({:shutdown, 1})

      {:error, reason} ->
        # The run never started: identical runtimes, an unavailable runtime,
        # or a missing/empty corpus. Not a skip -- a failure.
        IO.puts(:stderr, "SA2A conformance could not run: #{inspect(reason, pretty: true)}")
        exit({:shutdown, 1})
    end
  end

  defp emit(receipt, out_path, quiet?) do
    json = JSON.encode!(receipt)

    if quiet? do
      IO.puts(json)
    else
      IO.puts("")
      IO.puts(json)
      IO.puts("")
    end

    if out_path do
      File.write!(out_path, json)
      unless quiet?, do: IO.puts("receipt written to #{out_path}")
    end
  end

  defp summarise(receipt, verdict) do
    a = receipt["runtime_a"]
    b = receipt["runtime_b"]

    IO.puts("SA2A conformance court -- #{receipt["profile"]}")
    IO.puts("  graphlaw_version : #{receipt["graphlaw_version"]}")

    IO.puts(
      "  wasm_digest      : #{receipt["wasm_digest"]} (#{receipt["wasm_digest_algorithm"]})"
    )

    IO.puts("  corpus           : #{receipt["corpus"]["vector_count"]} vectors")
    IO.puts("  runtime_a        : #{a["host"]} / #{a["engine"]}")
    IO.puts("  runtime_b        : #{b["host"]} / #{b["engine"]}")
    IO.puts("")

    Enum.each(Conformance.assertion_names(), fn name ->
      assertion = receipt["assertions"][Atom.to_string(name)]

      status =
        cond do
          not assertion["computed"] -> "ABSENT (=FAIL)"
          assertion["value"] -> "true"
          true -> "false"
        end

      IO.puts("  #{String.pad_trailing(Atom.to_string(name), 22)} #{status}")

      if assertion["detail"], do: IO.puts("    #{assertion["detail"]}")

      Enum.each(assertion["divergences"], fn divergence ->
        IO.puts("    #{inspect(divergence)}")
      end)
    end)

    IO.puts("")
    IO.puts("  result           : #{verdict}")
  end

  defp put_if(opts, nil, _key), do: opts
  defp put_if(opts, value, key), do: Keyword.put(opts, key, value)

  defp put_module(opts, nil, _key), do: opts

  defp put_module(opts, value, key) do
    Keyword.put(opts, key, Module.concat([value]))
  end
end
