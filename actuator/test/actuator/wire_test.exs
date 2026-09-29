defmodule Actuator.WireTest do
  @moduledoc "Real Unix-domain socket round trips against a real Store; real mTLS handshakes."
  use ExUnit.Case, async: false
  import Bitwise
  alias Actuator.{Kit, Store}
  alias Actuator.Wire.{TLS, UDS}

  setup do
    Process.flag(:trap_exit, true)
    dir = Kit.tmp_dir("w")
    {:ok, store} = Store.start_link(state_dir: dir)
    {:ok, dir: dir, store: store}
  end

  defp frame(b) do
    Jason.encode!(%{
      "op" => "execute",
      "effect" => Base.url_encode64(b.effect_bytes, padding: false),
      "certificate" => Base.url_encode64(b.cert_bytes, padding: false)
    })
  end

  defp uds_call(path, payload) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, 4}, {:active, false}])
    :ok = :gen_tcp.send(s, payload)
    {:ok, resp} = :gen_tcp.recv(s, 0, 5_000)
    :gen_tcp.close(s)
    Jason.decode!(resp)
  end

  test "UDS: execute, replay, refusal with stage, no reconcile op, socket mode 0600", %{
    dir: dir,
    store: store
  } do
    b = Kit.build(state_dir: dir)
    path = Path.join(dir, "a.sock")
    {:ok, _} = UDS.start_link(path: path, store: store, ctx_fun: fn -> {:ok, b.ctx} end)

    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert %{"ok" => true} = uds_call(path, ~s({"op":"health"}))

    assert %{"ok" => true, "status" => "performed", "evidence" => %{"state" => "completed"}} =
             uds_call(path, frame(b))

    assert %{"ok" => true, "status" => "replayed"} = uds_call(path, frame(b))

    assert length(
             File.read!(Path.join(dir, "effect_ledger.jsonl"))
             |> String.split("\n", trim: true)
           ) == 1

    bad =
      Kit.build(
        state_dir: dir,
        keys: b.keys,
        nonce_prefix: "bad",
        effect: %{"effect_instance_id" => "ei:0005-abcdef"},
        tamper_sig: 0
      )

    assert %{"ok" => false, "stage" => 10, "refusal" => "bad_signature"} =
             uds_call(path, frame(bad))

    assert %{"ok" => false, "stage" => "parse", "refusal" => "malformed_request"} =
             uds_call(path, ~s({"op":"reconcile","effect_instance_id":"ei:0001-abcdef"}))

    assert %{"ok" => false, "stage" => "parse", "refusal" => "malformed_request"} =
             uds_call(path, "not json")

    assert %{"ok" => true, "evidence" => %{"state" => "completed"}} =
             uds_call(path, ~s({"op":"status","effect_instance_id":"ei:0001-abcdef"}))
  end

  test "UDS: an unavailable config fails closed at stage config", %{dir: dir, store: store} do
    b = Kit.build(state_dir: dir)
    path = Path.join(dir, "c.sock")

    {:ok, _} =
      UDS.start_link(path: path, store: store, ctx_fun: fn -> {:error, :config_unavailable} end)

    assert %{"ok" => false, "stage" => "config", "refusal" => "config_unavailable"} =
             uds_call(path, frame(b))

    refute File.exists?(Path.join(dir, "effect_ledger.jsonl")) and
             File.read!(Path.join(dir, "effect_ledger.jsonl")) != ""
  end

  test "mTLS options fail closed without cert, key and CA" do
    assert {:error, :mtls_config_incomplete} =
             TLS.ssl_options(certfile: "/nope", keyfile: "/nope")

    assert {:error, :mtls_config_incomplete} = TLS.ssl_options([])
  end

  @openssl System.find_executable("openssl")

  @tag skip:
         if(@openssl,
           do: false,
           else: "openssl not installed: mTLS handshake court needs real certs"
         )
  test "mTLS: a client with a CA-signed cert executes; a client without one gets nothing", %{
    dir: dir,
    store: store
  } do
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

    base = [
      :binary,
      {:packet, 4},
      {:active, false},
      {:versions, [:"tlsv1.3"]},
      {:verify, :verify_peer},
      {:cacertfile, String.to_charlist(pki.ca)},
      {:server_name_indication, ~c"localhost"}
    ]

    {:ok, good} =
      :ssl.connect(
        ~c"127.0.0.1",
        port,
        base ++
          [
            {:certfile, String.to_charlist(pki.client_cert)},
            {:keyfile, String.to_charlist(pki.client_key)}
          ],
        5_000
      )

    :ok = :ssl.send(good, frame(b))
    {:ok, resp} = :ssl.recv(good, 0, 5_000)
    assert %{"ok" => true, "status" => "performed"} = Jason.decode!(resp)
    :ssl.close(good)

    outcome =
      case :ssl.connect(~c"127.0.0.1", port, base, 5_000) do
        {:ok, s} ->
          _ = :ssl.send(s, ~s({"op":"health"}))
          r = :ssl.recv(s, 0, 3_000)
          :ssl.close(s)
          r

        {:error, _} = e ->
          e
      end

    assert {:error, _} = outcome
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
