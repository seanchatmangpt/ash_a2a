defmodule Actuator.Wire.TLS do
  @moduledoc """
  mTLS listener: TLS 1.3 only, `verify_peer` with `fail_if_no_peer_cert`, so a client
  without a certificate chaining to the pinned CA never reaches `Actuator.Wire`. Fails
  closed at start when cert, key or CA material is not configured.
  """
  use GenServer
  alias Actuator.Wire

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "SSL options for the listener, or {:error, :mtls_config_incomplete}."
  def ssl_options(opts) do
    files = for k <- [:certfile, :keyfile, :cacertfile], do: opts[k]

    if Enum.all?(files, &(is_binary(&1) and File.regular?(&1))) do
      {:ok,
       [
         :binary,
         {:packet, 4},
         {:packet_size, Wire.max_frame()},
         {:active, false},
         {:reuseaddr, true},
         {:ip, Keyword.get(opts, :ip, {127, 0, 0, 1})},
         {:versions, [:"tlsv1.3"]},
         {:certfile, String.to_charlist(opts[:certfile])},
         {:keyfile, String.to_charlist(opts[:keyfile])},
         {:cacertfile, String.to_charlist(opts[:cacertfile])},
         {:verify, :verify_peer},
         {:fail_if_no_peer_cert, true}
       ]}
    else
      {:error, :mtls_config_incomplete}
    end
  end

  @impl true
  def init(opts) do
    with {:ok, ssl} <- ssl_options(opts),
         {:ok, lsock} <- :ssl.listen(Keyword.get(opts, :port, 0), ssl) do
      store = Keyword.fetch!(opts, :store)
      ctx_fun = Keyword.fetch!(opts, :ctx_fun)
      spawn_link(fn -> accept(lsock, store, ctx_fun) end)
      {:ok, %{lsock: lsock}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def handle_call(:port, _, %{lsock: l} = st) do
    {:ok, {_, p}} = :ssl.sockname(l)
    {:reply, p, st}
  end

  defp accept(lsock, store, ctx_fun) do
    case :ssl.transport_accept(lsock) do
      {:ok, t} ->
        spawn(fn ->
          case :ssl.handshake(t, 10_000) do
            {:ok, sock} -> serve(sock, store, ctx_fun)
            _ -> :ok
          end
        end)

        accept(lsock, store, ctx_fun)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(lsock, store, ctx_fun)
    end
  end

  defp serve(sock, store, ctx_fun) do
    case :ssl.recv(sock, 0, 10_000) do
      {:ok, frame} ->
        _ = :ssl.send(sock, Wire.handle(store, ctx_fun, frame))
        serve(sock, store, ctx_fun)

      _ ->
        :ssl.close(sock)
    end
  end
end
