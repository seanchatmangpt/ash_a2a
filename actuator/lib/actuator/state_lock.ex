defmodule Actuator.StateLock do
  @moduledoc """
  Exclusive single-writer lock on a state directory: `<state_dir>/store.lock`, created with
  `:exclusive` (O_EXCL) and holding `"<os_pid> <erlang_pid>"`. A second Store on the same
  directory would fork the journal chain and brick the next boot, so acquisition fails closed
  with `{:state_dir_locked, holder}`.

  A lock whose holder is gone (OS process dead, or same VM and the Erlang pid dead) is stale
  and is taken over by atomically renaming it aside before re-creating it.
  """

  def path(dir), do: Path.join(dir, "store.lock")

  def acquire(dir, tries \\ 3)
  def acquire(_dir, 0), do: {:error, {:state_dir_locked, :contended}}

  def acquire(dir, tries) do
    lock = path(dir)
    me = "#{System.pid()} #{:erlang.pid_to_list(self()) |> List.to_string()}"

    case :file.open(lock, [:write, :exclusive, :binary, :raw]) do
      {:ok, fd} ->
        r = :file.write(fd, me)
        _ = :file.sync(fd)
        :file.close(fd)
        r

      {:error, :eexist} ->
        holder = File.read(lock)

        if alive?(holder) do
          {:error, {:state_dir_locked, holder_info(holder)}}
        else
          aside =
            lock <> ".stale." <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

          _ = File.rename(lock, aside)
          _ = File.rm(aside)
          acquire(dir, tries - 1)
        end

      {:error, reason} ->
        {:error, {:state_lock_unavailable, reason}}
    end
  end

  def release(dir) do
    lock = path(dir)

    with {:ok, body} <- File.read(lock),
         [_os, epid] <- String.split(body, " ", parts: 2),
         true <- epid == :erlang.pid_to_list(self()) |> List.to_string() do
      File.rm(lock)
    end

    :ok
  end

  defp holder_info({:ok, body}), do: body

  defp alive?({:ok, body}) do
    case String.split(body, " ", parts: 2) do
      [os, epid] ->
        cond do
          os == System.pid() ->
            try do
              epid |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
            rescue
              _ -> false
            end

          true ->
            case System.cmd("kill", ["-0", os], stderr_to_stdout: true) do
              {_, 0} -> true
              _ -> false
            end
        end

      _ ->
        false
    end
  end

  # unreadable/empty lock body (e.g. holder died between create and write): stale
  defp alive?(_), do: false
end
