# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.GraphlawEngineStopHostTest do
  @moduledoc """
  Permanent guard for a TOCTOU race in `AshA2A.Chicago.Fixtures.GraphlawEngine.stop_host/1`
  (`errc/ash-a2a-format`): the host is linked to the test process, so it can die between
  `Process.whereis/1` and `GenServer.stop/3`, failing an otherwise-passing test with
  `** (exit) no process` from its `on_exit` callback (seen once in a full `mix test` under
  load; not reproducible in isolation, hence this deterministic reconstruction).

  Real processes only: a real `WasmexHost` over the real vendored wasm, a real `Process.exit/2`
  kill, and a real dead pid. No collaborator is faked.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Chicago.Fixtures.GraphlawEngine, as: F

  test "stop_pid/1 on a pid that has already exited returns :ok instead of exiting :noproc" do
    name = F.start_host()
    pid = Process.whereis(name)
    ref = Process.monitor(pid)

    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    refute Process.alive?(pid)

    # The exact interleaving the race produces: a pid captured while alive, stopped after it died.
    assert F.stop_pid(pid) == :ok
  end

  test "stop_host/1 stops a live host and leaves no process behind" do
    name = F.start_host()
    pid = Process.whereis(name)
    assert is_pid(pid) and Process.alive?(pid)

    Process.unlink(pid)
    assert F.stop_host(name) == :ok
    refute Process.alive?(pid)
    assert Process.whereis(name) == nil
  end

  test "stop_host/1 on a name that is not registered returns :ok" do
    assert F.stop_host(Module.concat(F, "NeverStarted#{System.unique_integer([:positive])}")) ==
             :ok
  end
end
