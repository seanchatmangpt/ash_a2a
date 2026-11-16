defmodule Actuator.WireTlsCapTest do
  @moduledoc """
  W2-06. The mTLS listener's
  connection cap, driven over real :ssl connections with a real openssl-made PKI.
  """
  use ExUnit.Case, async: false
  alias Actuator.{Kit, Store}
  alias Actuator.Wire.TLS

  @openssl System.find_executable("openssl")

  @tag skip: if(@openssl, do: false, else: "openssl not installed")
  test "mTLS connections beyond the cap are closed, the listener survives and recovers" do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("tlscap")
    {:ok, store} = Store.start_link(state_dir: dir)
    pki = make_pki(dir)
    b = Kit.build(state_dir: dir)

    {:ok, tls} =
      TLS.start_link(
        store: store,
        ctx_fun: fn -> {:ok, b.ctx} end,
        port: 0,
        certfile: pki.server_cert,
        keyfile: pki.server_key,
        cacertfile: pki.ca
      )

    port = TLS.port(tls)

    opts = [
      :binary,
      {:packet, 4},
      {:active, false},
      {:versions, [:"tlsv1.3"]},
      {:verify, :verify_peer},
      {:cacertfile, String.to_charlist(pki.ca)},
      {:server_name_indication, ~c"localhost"},
      {:certfile, String.to_charlist(pki.client_cert)},
      {:keyfile, String.to_charlist(pki.client_key)}
    ]

    connect = fn -> :ssl.connect(~c"127.0.0.1", port, opts, 5_000) end

    # The acceptor is sequential and counts a connection before handshaking it, so once
    # connect/4 returns for the Nth client, that client is already counted.
    held =
      for _ <- 1..TLS.max_conns() do
        {:ok, s} = connect.()
        s
      end

    over =
      case connect.() do
        {:ok, s} ->
          _ = :ssl.send(s, ~s({"op":"health"}))
          r = :ssl.recv(s, 0, 3_000)
          :ssl.close(s)
          r

        {:error, _} = e ->
          e
      end

    assert {:error, _} = over

    # a held connection is still served: the cap refuses new peers, it does not drop old ones
    [first | rest] = held
    :ok = :ssl.send(first, ~s({"op":"health"}))
    assert {:ok, resp} = :ssl.recv(first, 0, 5_000)
    assert %{"ok" => true} = Jason.decode!(resp)

    Enum.each([first | rest], &:ssl.close/1)

    # slots are released asynchronously when the server sees the close; retry, bounded
    assert recovered?(connect, 50)
  end

  defp recovered?(_connect, 0), do: false

  defp recovered?(connect, n) do
    with {:ok, s} <- connect.(),
         :ok <- :ssl.send(s, ~s({"op":"health"})),
         {:ok, resp} <- :ssl.recv(s, 0, 1_000) do
      :ssl.close(s)
      match?(%{"ok" => true}, Jason.decode!(resp))
    else
      _ ->
        # wait on a timer message rather than sleeping the test process unconditionally
        ref = make_ref()
        Process.send_after(self(), {:retry, ref}, 100)

        receive do
          {:retry, ^ref} -> :ok
        end

        recovered?(connect, n - 1)
    end
  end

  defp make_pki(dir) do
    f = &Path.join(dir, &1)

    sh = fn args ->
      {out, 0} = System.cmd(@openssl, args, stderr_to_stdout: true)
      out
    end

    sh.(
      ~w(req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=actuator-test-ca -keyout #{f.("ca.key")} -out #{f.("ca.pem")})
    )

    for {name, cn, ext} <- [
          {"server", "localhost", "subjectAltName=DNS:localhost,IP:127.0.0.1"},
          {"client", "authority", "subjectAltName=DNS:authority"}
        ] do
      sh.(
        ~w(req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=#{cn} -keyout #{f.(name <> ".key")} -out #{f.(name <> ".csr")})
      )

      File.write!(f.(name <> ".ext"), ext <> "\n")

      sh.(
        ~w(x509 -req -in #{f.(name <> ".csr")} -CA #{f.("ca.pem")} -CAkey #{f.("ca.key")} -CAcreateserial -days 2 -extfile #{f.(name <> ".ext")} -out #{f.(name <> ".pem")})
      )
    end

    %{
      ca: f.("ca.pem"),
      server_cert: f.("server.pem"),
      server_key: f.("server.key"),
      client_cert: f.("client.pem"),
      client_key: f.("client.key")
    }
  end
end
