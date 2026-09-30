defmodule Actuator.Wire.UDS do
  @moduledoc """
  Unix-domain-socket listener (mode 0600). One request frame per round trip, served
  serially per connection; the Store serializes execution. No TCP port is opened.
  """
  use GenServer
  alias Actuator.Wire

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    store = Keyword.fetch!(opts, :store)
    ctx_fun = Keyword.fetch!(opts, :ctx_fun)
    _ = File.rm(path)

    case bind(path) do
      {:ok, lsock} ->
        parent = self()
        pid = spawn_link(fn -> accept(lsock, store, ctx_fun) end)
        {:ok, %{lsock: lsock, path: path, acceptor: pid, parent: parent}}

      {:error, reason} ->
        {:stop, {:uds_listen_failed, reason}}
    end
  end

  # No chmod-after-listen window: the socket is bound inside a private 0700 staging directory,
  # made 0600 there, and only then renamed onto the public path. The staging path is longer than
  # the public path, so near the OS sun_path limit (104 bytes on macOS) staging cannot bind; in
  # that case bind directly at the public path, which is only admissible when the parent
  # directory is itself private (no group/world access), so the pre-chmod window is unobservable.
  defp bind(path) do
    case bind_staged(path) do
      {:ok, _} = ok -> ok
      {:error, _} -> bind_direct(path)
    end
  end

  defp listen(at) do
    :gen_tcp.listen(0, [
      :binary,
      {:ifaddr, {:local, at}},
      {:packet, 4},
      {:packet_size, Wire.max_frame()},
      {:active, false}
    ])
  end

  defp bind_staged(path) do
    stage =
      Path.join(
        Path.dirname(path),
        ".u" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      )

    File.mkdir!(stage)
    File.chmod!(stage, 0o700)
    staged = Path.join(stage, "s")

    result =
      with {:ok, lsock} <- listen(staged) do
        File.chmod!(staged, 0o600)
        :ok = File.rename(staged, path)
        {:ok, lsock}
      end

    File.rmdir!(stage)
    result
  end

  defp bind_direct(path) do
    import Bitwise

    case File.stat(Path.dirname(path)) do
      {:ok, %{mode: mode}} when (mode &&& 0o077) == 0 ->
        with {:ok, lsock} <- listen(path) do
          File.chmod!(path, 0o600)
          {:ok, lsock}
        end

      {:ok, _} ->
        {:error, :path_too_long_and_parent_not_private}

      {:error, _} = e ->
        e
    end
  end

  @impl true
  def terminate(_, %{lsock: l, path: p}) do
    :gen_tcp.close(l)
    File.rm(p)
  end

  defp accept(lsock, store, ctx_fun) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid =
          spawn(fn ->
            receive do
              :go -> serve(sock, store, ctx_fun)
            end
          end)

        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(lsock, store, ctx_fun)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, store, ctx_fun) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, frame} ->
        :ok = :gen_tcp.send(sock, Wire.handle(store, ctx_fun, frame))
        serve(sock, store, ctx_fun)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end
end
