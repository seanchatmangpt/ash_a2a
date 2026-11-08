# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshA2a.PplanCourts do
  @shortdoc "One-command runner for the ash_pplan integration courts (tag: :pplan_court)"

  @moduledoc """
  One-command runner for the cross-repo ash_pplan integration courts.

  Court files are ExUnit tests tagged `@moduletag :pplan_court` anywhere
  under `test/` (I-lanes land them under `test/replan/`, `test/execution/`,
  etc.). This task discovers them, runs `mix test` against them with the
  `:pplan_court` filter, and emits a receipt at
  `receipts/pplan-courts-<date>.md` with a Standing line and per-file exits.

  Fail-closed law: any court file that fails to compile makes the task exit
  nonzero naming the file -- compile-abort is not zero failures. A run with
  zero discovered courts is NOT a pass: the receipt says `UNVERIFIED` and the
  census is printed loudly, but the exit is 0 only when the census is honest
  (no courts landed yet is a legal state during the wave).

      mix ash_a2a.pplan_courts
      mix ash_a2a.pplan_courts --only other_tag
      mix ash_a2a.pplan_courts --with-oracle        # start airbus oracle daemon
      mix ash_a2a.pplan_courts --ash-pplan-path PATH

  Options:

    * `--only TAG` -- filter tag (default `pplan_court`)
    * `--with-oracle` -- start `~/ash_pplan/scripts/airbus_oracle_daemon.py`
      before the courts and stop it after (only needed by parity courts that
      talk to the oracle; skipped loudly if the script is absent)
    * `--ash-pplan-path PATH` -- ash_pplan checkout for path mode
      (default: `~/ash_pplan` if it exists; exported as `ASH_PPLAN_PATH`)
    * `--run-serial/--no-run-serial` -- the `mix test` alias excludes
      `:serial`-tagged tests in some invocation contexts, so a court whose
      tests carry `@tag :serial` (e.g. the I4 durability court) can run 0
      tests under a plain `--only` filter. Default true: each court file is
      run ONCE with `--only TAG --include serial` — `--include serial` is
      ExUnit's native way to cancel the alias's `--exclude serial`, so the
      pass is the full census under either alias behavior (a single pass,
      never two merged passes: two passes double-count every test).
    * `--receipt PATH` -- receipt output path (default
      `receipts/pplan-courts-<date>.md`)

  Exits nonzero if: any court file fails to compile (exit 2 census), any
  court test fails, or the oracle was requested but could not start.
  """

  use Mix.Task

  @switches [only: :string, with_oracle: :boolean, ash_pplan_path: :string, receipt: :string, run_serial: :boolean]
  @aliases [o: :only]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    tag = opts[:only] || "pplan_court"
    pplan_path = opts[:ash_pplan_path] || default_pplan_path()
    started = System.system_time(:second)

    court_files = discover(tag)

    if court_files == [] do
      Mix.shell().info("""
      [pplan_courts] NO COURT FILES FOUND for tag :#{tag}.
      [pplan_courts] Courts are ExUnit files under test/ tagged @moduletag :#{tag}.
      [pplan_courts] If I-lanes have not landed yet, this is an honest empty
      [pplan_courts] census -- the receipt will say UNVERIFIED, never PASS.
      """)
    end

    oracle = maybe_start_oracle(opts, pplan_path)

    receipts_dir = Path.join(File.cwd!(), "receipts")
    File.mkdir_p!(receipts_dir)

    receipt_path =
      opts[:receipt] || Path.join(receipts_dir, "pplan-courts-#{date_str(started)}.md")

    env = %{"ASH_PPLAN_PATH" => pplan_path}

    {results, overall} =
      if court_files == [] do
        {[], :no_courts}
      else
        run_courts(court_files, tag, env, Keyword.get(opts, :run_serial, true))
      end

    maybe_stop_oracle(oracle)

    standing =
      case {overall, results} do
        {:no_courts, _} -> "UNVERIFIED"
        {_, results} -> if Enum.all?(results, &(&1.status == :pass)), do: "PASS", else: "BLOCKED"
      end

    receipt = render_receipt(standing, tag, court_files, results, overall, receipt_path)
    File.write!(receipt_path, receipt)

    Mix.shell().info("""
    [pplan_courts] Standing: #{standing}
    [pplan_courts] Receipt: #{receipt_path}
    """)

    case overall do
      :ok ->
        :ok

      :no_courts ->
        :ok

      :compile_abort ->
        bad = Enum.filter(results, &(&1.status == :compile_abort))
        names = Enum.map_join(bad, ", ", & &1.file)
        Mix.raise("compile-abort in court file(s): #{names} -- compile-abort != zero failures")

      :failures ->
        Mix.raise("court test failures (see receipt: #{receipt_path})")
    end
  end

  defp discover(tag) do
    "test"
    |> Path.join("**/*.exs")
    |> Path.wildcard()
    |> Enum.filter(fn file ->
      file
      |> File.read!()
      |> String.contains?(tag)
    end)
  end

  defp run_courts(files, tag, env, run_serial?) do
    results =
      Enum.map(files, fn file ->
        args =
          if run_serial? do
            ["test", file, "--only", tag, "--include", "serial"]
          else
            ["test", file, "--only", tag]
          end

        run_pass(file, args, env)
      end)

    overall =
      cond do
        Enum.any?(results, &(&1.status == :compile_abort)) -> :compile_abort
        Enum.any?(results, &(&1.status == :fail)) -> :failures
        true -> :ok
      end

    {results, overall}
  end

  defp run_pass(file, args, env) do
    {output, rc} =
      System.cmd("mix", args, env: env, stderr_to_stdout: true, into: [])

    output = IO.iodata_to_binary(output)

    status =
      cond do
        rc == 0 -> :pass
        compile_error?(output) -> :compile_abort
        true -> :fail
      end

    %{file: file, rc: rc, status: status, summary: summary_line(output)}
  end

  defp compile_error?(output) do
    output =~ "== Compilation error" or output =~ "** (CompileError" or
      output =~ "** (SyntaxError" or output =~ "** (UndefinedFunctionError"
  end

  defp summary_line(output) do
    output
    |> String.split("\n")
    |> Enum.find("", fn line -> line =~ ~r/\d+ tests?/ and line =~ ~r/\d+ failures?/ end)
    |> String.trim()
  end

  # minimal unblock (lane I2, compile-freeze SLA): `opts[:with_oracle]` is
  # Access.get/2, unlawful in a guard — keyword access moved into a body `if`.
  defp maybe_start_oracle(opts, pplan_path) do
    if Keyword.get(opts, :with_oracle) == true do
      start_oracle(pplan_path)
    else
      nil
    end
  end

  defp start_oracle(pplan_path) do
    script = Path.join(pplan_path, "scripts/airbus_oracle_daemon.py")

    if File.exists?(script) do
      port =
        Port.open({:spawn_executable, python3()},
          args: [script],
          env: [{~c"ASH_PPLAN_PATH", String.to_charlist(pplan_path)}]
        )

      Mix.shell().info("[pplan_courts] oracle daemon started (port #{inspect(port.id)})")
      {:port, port, script}
    else
      Mix.shell().info("[pplan_courts] --with-oracle requested but #{script} not found -- LOUD SKIP")
      {:skipped, script}
    end
  end

  defp maybe_stop_oracle({:port, port, _}) do
    Port.close(port)
    :ok
  end

  defp maybe_stop_oracle(_), do: :ok

  defp python3 do
    case System.find_executable("python3") do
      nil -> Mix.raise("python3 not found on PATH -- cannot start oracle daemon")
      path -> path
    end
  end

  defp default_pplan_path do
    path = Path.expand("~/ash_pplan")
    if File.dir?(path), do: path, else: Path.expand(".")
  end

  defp date_str(seconds) do
    seconds
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y%m%d")
  end

  defp render_receipt(standing, tag, files, results, overall, path) do
    date = DateTime.utc_now() |> DateTime.to_iso8601()

    rows =
      case results do
        [] ->
          "  (no court files discovered for tag :#{tag} -- honest empty census, UNVERIFIED)"

        results ->
          results
          |> Enum.map(fn r ->
            "  - #{r.file}: rc=#{r.rc} status=#{r.status} #{r.summary}"
          end)
          |> Enum.join("\n")
      end

    """
    # pplan courts receipt (#{date})

    Standing: #{standing}

    - tag: :#{tag}
    - discovered files: #{length(files)}
    - overall: #{overall}
    - receipt path: #{path}

    ## Per-file exits

    #{rows}
    """
  end
end
