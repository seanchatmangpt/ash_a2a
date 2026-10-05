# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# C2 court child watchdog: a court child never outlives the test VM that started it.
# Polls the parent OS pid every 2s and halts when it is gone (so a crashed/killed court run
# leaves no orphaned actuator/authority/keymaster processes behind).
case System.get_env("C2_PARENT_PID") do
  nil ->
    :ok

  parent ->
    spawn(fn ->
      loop = fn loop ->
        Process.sleep(2_000)
        {_, code} = System.cmd("kill", ["-0", parent], stderr_to_stdout: true)
        if code == 0, do: loop.(loop), else: System.halt(0)
      end

      loop.(loop)
    end)
end
