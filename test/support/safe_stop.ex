defmodule AshA2A.TestSupport.SafeStop do
  @moduledoc """
  Teardown helper: stops a GenServer, tolerating a process that exits
  between the liveness check and the stop call (or is already gone).
  """

  @spec stop(GenServer.server()) :: :ok
  def stop(pid) do
    if is_pid(pid) and not Process.alive?(pid) do
      :ok
    else
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
