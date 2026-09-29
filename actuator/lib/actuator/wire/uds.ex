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
    _ = File.rm(path)

    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, path}},
        {:packet, 4},
        {:packet_size, Wire.max_frame()},
        {:active, false}
      ])

    File.chmod!(path, 0o600)
    store = Keyword.fetch!(opts, :store)
    ctx_fun = Keyword.fetch!(opts, :ctx_fun)
    parent = self()
    pid = spawn_link(fn -> accept(lsock, store, ctx_fun) end)
    {:ok, %{lsock: lsock, path: path, acceptor: pid, parent: parent}}
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
