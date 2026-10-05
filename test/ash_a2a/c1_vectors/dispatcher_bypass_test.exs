# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1DispatcherBypassTest do
  use ExUnit.Case, async: true

  test "legacy direct dispatch refused" do
    assert {:error, :kernel_bypass} =
             AshA2A.ConsequenceKernel.CompleteMediation.admit_call_path([AshA2A.Dispatcher])
  end
end
