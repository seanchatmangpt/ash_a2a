# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Proc do
  @moduledoc """
  A real child OS process (`mix run --no-halt ...` in another project directory, with its
  own `MIX_BUILD_ROOT`), owned by a dedicated relay process that appends its output to a
  log file and reports readiness (`C2_READY <json>` line) and exit.

  SIGKILL is a real `kill -9` of the OS pid the child reported about itself (`os_pid` in
  its READY line), never a graceful stop.
  """
  defstruct [:role, :owner, :os_pid, :ready, :log, :ref]

  @type t :: %__MODULE__{}

  @doc """
  Start `mix run --no-halt --no-compile --no-deps-check <script>` in `dir`.

  Options: `:env` (list of `{name, value}` given to the child only), `:log` (file),
  `:script` (path), `:timeout` ms to wait for READY.
  """
  @spec start(String.t(), Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(role, dir, opts) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    parent = self()
    ref = make_ref()
    log = Keyword.fetch!(opts, :log)
    File.mkdir_p!(Path.dirname(log))
    File.write!(log, "")
    args = ["run", "--no-halt", "--no-compile", "--no-deps-check"] ++ List.wrap(opts[:script])

    env =
      for {k, v} <- Keyword.get(opts, :env, []),
          do: {String.to_charlist(k), String.to_charlist(v)}

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, mix}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 65_536},
            {:args, args},
            {:cd, dir},
            {:env, env}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(parent, {:c2_spawned, ref, os_pid})
        relay(port, parent, ref, log)
      end)

    timeout = Keyword.get(opts, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    os_pid =
      receive do
        {:c2_spawned, ^ref, pid} -> pid
      after
        10_000 -> nil
      end

    case Keyword.get(opts, :ready, :line) do
      :line -> await_line(owner, ref, log, timeout, role, os_pid)
      {:poll, fun} -> await_poll(owner, ref, log, os_pid, fun, deadline, role)
    end
  end

  defp await_line(owner, ref, log, timeout, role, os_pid) do
    receive do
      {:c2_ready, ^ref, ready} ->
        {:ok,
         %__MODULE__{
           role: role,
           owner: owner,
           ref: ref,
           ready: ready,
           log: log,
           os_pid: parse_pid(ready["os_pid"])
         }}

      {:c2_exit, ^ref, status} ->
        {:error, {:exited_before_ready, status, tail(log)}}
    after
      timeout ->
        kill_os(os_pid)
        Process.exit(owner, :kill)
        {:error, {:ready_timeout, tail(log)}}
    end
  end

  defp kill_os(nil), do: :ok

  defp kill_os(pid),
    do: System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)

  defp await_poll(owner, ref, log, os_pid, fun, deadline, role) do
    receive do
      {:c2_exit, ^ref, status} -> {:error, {:exited_before_ready, status, tail(log)}}
    after
      0 ->
        cond do
          fun.() ->
            {:ok,
             %__MODULE__{role: role, owner: owner, ref: ref, ready: %{}, log: log, os_pid: os_pid}}

          System.monotonic_time(:millisecond) > deadline ->
            kill_os(os_pid)
            Process.exit(owner, :kill)
            {:error, {:ready_timeout, tail(log)}}

          true ->
            Process.sleep(100)
            await_poll(owner, ref, log, os_pid, fun, deadline, role)
        end
    end
  end

  defp relay(port, parent, ref, log) do
    receive do
      {^port, {:data, {_eol, line}}} ->
        File.write(log, line <> "\n", [:append])

        case line do
          "C2_READY " <> json -> send(parent, {:c2_ready, ref, Jason.decode!(json)})
          _ -> :ok
        end

        relay(port, parent, ref, log)

      {^port, {:exit_status, status}} ->
        File.write(log, "C2_EXIT #{status}\n", [:append])
        send(parent, {:c2_exit, ref, status})
        :ok

      :stop ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp parse_pid(p) when is_integer(p), do: p
  defp parse_pid(p) when is_binary(p), do: String.to_integer(p)

  @doc "Real SIGKILL of the child; returns once the OS pid is gone."
  @spec kill9(t()) :: :ok
  def kill9(%__MODULE__{os_pid: pid}) do
    _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    wait_gone(pid, 100)
  end

  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{os_pid: pid}), do: os_alive?(pid)

  defp os_alive?(pid) do
    {_, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    code == 0
  end

  defp wait_gone(_pid, 0), do: :ok

  defp wait_gone(pid, n) do
    if os_alive?(pid) do
      Process.sleep(20)
      wait_gone(pid, n - 1)
    else
      :ok
    end
  end

  @doc "Graceful-enough stop for teardown (SIGKILL: the children hold no state that needs a flush)."
  def stop(nil), do: :ok

  def stop(%__MODULE__{} = p) do
    kill9(p)
    send(p.owner, :stop)
    :ok
  end

  def tail(log) do
    case File.read(log) do
      {:ok, data} -> data |> String.split("\n") |> Enum.take(-25) |> Enum.join("\n")
      _ -> ""
    end
  end
end
