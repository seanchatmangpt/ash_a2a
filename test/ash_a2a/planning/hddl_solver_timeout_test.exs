defmodule AshA2A.Planning.HddlSolverTimeoutTest do
  @moduledoc """
  CWE-770 court: a real hung subprocess and a real flooding subprocess must be
  refused with typed codes and the OS process must not survive. DB-free.
  """
  use ExUnit.Case, async: true

  alias AshA2A.Planning.HddlSolver

  @tag :tmp_dir
  test "hung subprocess is killed at the wall-clock timeout", %{tmp_dir: dir} do
    marker = Path.join(dir, "hung.pid")
    script = Path.join(dir, "hang.sh")
    File.write!(script, "#!/bin/sh\necho $$ > #{marker}\nexec sleep 300\n")
    File.chmod!(script, 0o755)

    {micros, result} =
      :timer.tc(fn ->
        HddlSolver.solve("d", "p", cli_path: script, timeout_ms: 400, tmp_dir: dir)
      end)

    assert {:error, %{code: :hddl_timeout}} = result
    assert micros < 5_000_000

    pid = marker |> File.read!() |> String.trim()
    Process.sleep(200)
    {out, _} = System.cmd("sh", ["-c", "kill -0 #{pid} 2>&1; echo rc=$?"])
    assert out =~ "rc=1", "hung child #{pid} still alive: #{out}"
  end

  @tag :tmp_dir
  test "flooding subprocess is refused at the output cap", %{tmp_dir: dir} do
    script = Path.join(dir, "flood.sh")
    File.write!(script, "#!/bin/sh\nexec yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n")
    File.chmod!(script, 0o755)

    assert {:error, %{code: :hddl_output_too_large}} =
             HddlSolver.solve("d", "p",
               cli_path: script,
               timeout_ms: 10_000,
               max_output_bytes: 50_000,
               tmp_dir: dir
             )
  end

  @tag :tmp_dir
  test "well-behaved subprocess still decodes normally", %{tmp_dir: dir} do
    script = Path.join(dir, "ok.sh")
    File.write!(script, ~s(#!/bin/sh\necho '{"solved": true, "plan": []}'\n))
    File.chmod!(script, 0o755)

    assert {:ok, %{"solved" => true}} = HddlSolver.solve("d", "p", cli_path: script, tmp_dir: dir)
  end
end
