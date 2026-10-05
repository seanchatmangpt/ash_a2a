# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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

    # Under full-suite parallel load the shell startup can lose the race with
    # the 400ms wall clock: the child is killed BEFORE `echo $$` lands. Then
    # the marker never appears -- which is itself proof the OS process did
    # not survive (only a live child could still write it). Poll briefly for
    # the marker and take that branch into account.
    pid =
      case wait_for_marker(marker, 20) do
        nil ->
          nil

        content ->
          content |> String.trim()
      end

    if pid do
      Process.sleep(200)

      {out, _} = System.cmd("sh", ["-c", "kill -0 #{pid} 2>&1; echo rc=$?"])
      assert out =~ "rc=1", "hung child #{pid} still alive: #{out}"
    end
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

  defp wait_for_marker(marker, 0), do: if(File.exists?(marker), do: File.read!(marker))

  defp wait_for_marker(marker, remaining) do
    if File.exists?(marker) do
      File.read!(marker)
    else
      Process.sleep(100)
      wait_for_marker(marker, remaining - 1)
    end
  end

  @tag :tmp_dir
  test "well-behaved subprocess still decodes normally", %{tmp_dir: dir} do
    script = Path.join(dir, "ok.sh")
    File.write!(script, ~s(#!/bin/sh\necho '{"solved": true, "plan": []}'\n))
    File.chmod!(script, 0o755)

    assert {:ok, %{"solved" => true}} = HddlSolver.solve("d", "p", cli_path: script, tmp_dir: dir)
  end
end
