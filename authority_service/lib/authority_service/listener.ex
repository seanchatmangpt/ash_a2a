defmodule AuthorityService.Listener do
  @moduledoc """
  Typed wire: one length-prefixed JSON frame per connection (`<<len::32, json>>`), size
  bounded by `:max_bytes`, response in the same framing. No Erlang distribution.

  Transports: `{:unix, path}` (socket file mode 0660) or
  `{:tls, port, [certfile:, keyfile:, cacertfile:]}` (TLS 1.3, mutual authentication:
  `verify_peer` + `fail_if_no_peer_cert`).

  Ops: `"issue"` -> `{"ok": true, "certificate": ...}` or
  `{"ok": false, "refusal": code, "detail": [...]}`. Anything else is refused.
  """
  use GenServer
  alias AuthorityService.Issuer

  @default_max 65_536
  @recv_timeout 5_000
  @max_conns 64

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Port of a TLS listener (useful when started with port 0)."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)

    with {:ok, lsock} <- listen(transport) do
      st = %{
        lsock: lsock,
        kind: kind(transport),
        issuer: Keyword.fetch!(opts, :issuer),
        max: Keyword.get(opts, :max_bytes, @default_max),
        conns: :counters.new(1, []),
        transport: transport
      }

      parent = self()
      spawn_link(fn -> accept(st, parent) end)
      {:ok, st}
    else
      {:error, reason} -> {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _, %{lsock: l, kind: :tls} = st) do
    {:ok, {_, p}} = :ssl.sockname(l)
    {:reply, p, st}
  end

  def handle_call(:port, _, st), do: {:reply, nil, st}

  defp kind({:unix, _}), do: :unix
  defp kind({:tls, _, _}), do: :tls

  defp listen({:unix, path}) do
    File.rm(path)

    with {:ok, l} <-
           :gen_tcp.listen(0, [
             :binary,
             {:ifaddr, {:local, String.to_charlist(path)}},
             {:active, false},
             {:packet, :raw},
             {:backlog, 128}
           ]) do
      File.chmod(path, 0o660)
      {:ok, l}
    end
  end

  defp listen({:tls, port, tls}) do
    :ssl.listen(port, [
      :binary,
      {:active, false},
      {:packet, :raw},
      {:reuseaddr, true},
      {:versions, [:"tlsv1.3"]},
      {:certfile, Keyword.fetch!(tls, :certfile)},
      {:keyfile, Keyword.fetch!(tls, :keyfile)},
      {:cacertfile, Keyword.fetch!(tls, :cacertfile)},
      {:verify, :verify_peer},
      {:fail_if_no_peer_cert, true}
    ])
  end

  defp accept(st, parent) do
    case do_accept(st) do
      {:ok, sock} ->
        if :counters.get(st.conns, 1) >= @max_conns do
          close(st.kind, sock)
        else
          :counters.add(st.conns, 1, 1)

          pid =
            spawn(fn ->
              try do
                handle(st, sock)
              after
                :counters.sub(st.conns, 1, 1)
                close(st.kind, sock)
              end
            end)

          controlling(st.kind, sock, pid)
        end

        accept(st, parent)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(st, parent)
    end
  end

  defp do_accept(%{kind: :unix, lsock: l}), do: :gen_tcp.accept(l)

  defp do_accept(%{kind: :tls, lsock: l}) do
    with {:ok, s} <- :ssl.transport_accept(l),
         {:ok, s} <- :ssl.handshake(s, @recv_timeout) do
      {:ok, s}
    end
  end

  defp controlling(:unix, s, pid), do: :gen_tcp.controlling_process(s, pid)
  defp controlling(:tls, s, pid), do: :ssl.controlling_process(s, pid)

  defp close(:unix, s), do: :gen_tcp.close(s)
  defp close(:tls, s), do: :ssl.close(s)

  defp recv(:unix, s, n), do: :gen_tcp.recv(s, n, @recv_timeout)
  defp recv(:tls, s, n), do: :ssl.recv(s, n, @recv_timeout)
  defp send_(:unix, s, d), do: :gen_tcp.send(s, d)
  defp send_(:tls, s, d), do: :ssl.send(s, d)

  defp handle(st, sock) do
    reply =
      with {:ok, <<len::32>>} <- recv(st.kind, sock, 4) |> or_malformed(),
           true <- len <= st.max or {:refuse, :request_too_large},
           {:ok, body} <-
             if(len == 0, do: {:ok, <<>>}, else: recv(st.kind, sock, len)) |> or_malformed(),
           {:ok, req} <- Jason.decode(body) |> or_malformed(),
           true <- is_map(req) or {:refuse, :malformed_request} do
        dispatch(req, st)
      else
        {:refuse, code} -> refusal(code, [])
        _ -> refusal(:malformed_request, [])
      end

    body = Jason.encode!(reply)
    send_(st.kind, sock, <<byte_size(body)::32, body::binary>>)
  end

  defp or_malformed({:ok, _} = ok), do: ok
  defp or_malformed(_), do: {:refuse, :malformed_request}

  defp dispatch(%{"op" => "issue"} = req, st) do
    case Issuer.issue(st.issuer, req) do
      {:ok, cert} -> %{"ok" => true, "certificate" => cert}
      {:refused, code, detail} -> refusal(code, detail)
    end
  end

  defp dispatch(_, _), do: refusal(:unknown_op, [])

  defp refusal(code, detail) do
    %{
      "ok" => false,
      "refusal" => Atom.to_string(code),
      "detail" => Enum.map(detail, &if(is_atom(&1), do: Atom.to_string(&1), else: "other"))
    }
  end
end
