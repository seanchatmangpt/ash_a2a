# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.GraphLaw.SubprocessTest do
  @moduledoc """
  Chicago-school court for `AshA2A.GraphLaw.Subprocess` (PERF-03, PERF-12):
  real OS processes (`sh`, `sleep`, `kill -0`), no doubles. `async: false`
  because the concurrency cap is a node-wide counter.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.Subprocess

  test "a completed process returns stdout and its exit status; stderr is not merged" do
    assert {:ok, {"out\n", 3}} =
             Subprocess.run("sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout_ms: 5_000)
  end

  test "a hung process is killed at the deadline and typed :graphlaw_host_timeout" do
    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :graphlaw_host_timeout, os_pid: os_pid}} =
             Subprocess.run("sleep", ["30"], timeout_ms: 200)

    assert System.monotonic_time(:millisecond) - started < 5_000
    # The OS process is really gone, not merely abandoned.
    Process.sleep(100)

    assert {_, status} =
             System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert status != 0
    assert Subprocess.in_flight() == 0
    refute_received {_port, {:exit_status, _}}
  end

  test "a spawn over the concurrency cap is shed, not queued" do
    parent = self()

    holder =
      Task.async(fn ->
        send(parent, :holding)
        Subprocess.run("sleep", ["2"], timeout_ms: 5_000, max_concurrency: 1)
      end)

    assert_receive :holding
    wait_until(fn -> Subprocess.in_flight() >= 1 end)

    assert {:error, %{code: :graphlaw_host_saturated, max_concurrency: 1}} =
             Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)

    assert {:ok, {"", 0}} = Task.await(holder, 10_000)
    assert Subprocess.in_flight() == 0
    assert {:ok, {"x\n", 0}} = Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)
  end

  test "run/3 returns only after its slot is released: back-to-back runs at cap 1 are never shed" do
    # The slot used to be released by a watcher process asynchronously, so `run/3`
    # could return while `in_flight/0` was still 1 and an immediate re-run at the
    # cap was spuriously shed (`:graphlaw_host_saturated`).
    results =
      for _ <- 1..300 do
        {Subprocess.run("true", [], max_concurrency: 1), Subprocess.in_flight()}
      end

    assert Enum.all?(results, fn {run, in_flight} ->
             match?({:ok, {"", 0}}, run) and in_flight == 0
           end),
           "a run was shed or returned before releasing its slot: " <>
             inspect(
               Enum.find(results, fn {run, n} -> not match?({:ok, {"", 0}}, run) or n != 0 end)
             )
  end

  test "a caller killed mid-run releases its slot and its OS process" do
    marker = "31.#{System.unique_integer([:positive])}"
    task = Task.async(fn -> Subprocess.run("sleep", [marker], timeout_ms: 60_000) end)

    wait_until(fn -> Subprocess.in_flight() >= 1 end)
    wait_until(fn -> match?({_, 0}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
    assert Task.shutdown(task, :brutal_kill) == nil

    wait_until(fn -> Subprocess.in_flight() == 0 end)
    wait_until(fn -> match?({_, 1}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
  end

  test "a missing executable is a typed spawn failure" do
    assert {:error, %{code: :graphlaw_host_spawn_failed}} =
             Subprocess.run("definitely-not-an-executable-xyz", [])
  end

  test "the peer transport's availability probe spawns node at most once per artifact" do
    if System.find_executable("node") do
      assert AshA2A.Semantic.GraphLaw.Wasm.available?()
      {us, true} = :timer.tc(&AshA2A.Semantic.GraphLaw.Wasm.available?/0)
      # A node spawn + 3.2 MB instantiation measured ~100 ms; a memo hit is
      # two stat calls and a persistent_term read.
      assert us < 10_000, "memoized available?/0 took #{us} us"
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
