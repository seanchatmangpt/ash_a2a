defmodule AshA2A.Telemetry.OcelForwarderEgressTest do
  @moduledoc """
  CWE-918 court: the OCEL forwarder must not connect to loopback / link-local /
  metadata endpoints under the strict default policy. Oracle: a real local TCP
  listener that records whether any connection arrives (independent of the code
  under test). DB-free.
  """
  use ExUnit.Case, async: false

  alias AshA2A.Telemetry.OcelForwarder

  setup do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    parent = self()

    acceptor =
      spawn_link(fn ->
        case :gen_tcp.accept(listen, 1_500) do
          {:ok, sock} ->
            data =
              case :gen_tcp.recv(sock, 0, 500) do
                {:ok, d} -> d
                _ -> ""
              end

            :gen_tcp.send(
              sock,
              "HTTP/1.1 201 Created\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

            :gen_tcp.close(sock)
            send(parent, {:accepted, data})

          {:error, :timeout} ->
            send(parent, :nothing_accepted)
        end
      end)

    prev_policy = Application.fetch_env(:ash_a2a, :ocel_egress_policy)
    :ok = OcelForwarder.attach!()

    on_exit(fn ->
      OcelForwarder.detach()
      Application.delete_env(:ash_a2a, :ocel_ingest_url)

      case prev_policy do
        {:ok, v} -> Application.put_env(:ash_a2a, :ocel_egress_policy, v)
        :error -> Application.delete_env(:ash_a2a, :ocel_egress_policy)
      end

      :gen_tcp.close(listen)
    end)

    {:ok, port: port, acceptor: acceptor}
  end

  defp fire do
    :telemetry.execute([:ash_a2a, :dispatch, :stop], %{duration: 1}, %{
      resource_or_domain: EgressCourtDomain,
      skill_name: :probe,
      reply_type: :reply
    })
  end

  defp wait_failed(reason) do
    receive do
      {:ocel_failed, %{reason: ^reason}} -> :ok
      {:ocel_failed, other} -> flunk("unexpected failure metadata #{inspect(other)}")
    after
      2_000 -> flunk("no ocel failed event for #{inspect(reason)}")
    end
  end

  defp capture_failed do
    parent = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:ash_a2a, :ocel, :failed],
      fn _e, _m, meta, _ -> send(parent, {:ocel_failed, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "strict policy: loopback ingest URL is refused and the listener receives nothing", %{
    port: port
  } do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "https://127.0.0.1:#{port}")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_private_address)
    assert_receive :nothing_accepted, 3_000
    refute_received {:accepted, _}
  end

  test "strict policy: plain http to a public-looking host is refused by scheme" do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://93.184.216.34:9")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_scheme)
  end

  test "strict policy: 169.254.169.254 metadata literal is refused before any connect" do
    Application.put_env(:ash_a2a, :ocel_egress_policy, [])
    Application.put_env(:ash_a2a, :ocel_ingest_url, "https://169.254.169.254")
    capture_failed()
    fire()
    wait_failed(:refused_webhook_private_address)
  end

  test "policy admission is synchronous: EndpointPolicy refuses without connecting" do
    assert {:error, :refused_webhook_private_address, _} =
             AshA2A.Egress.EndpointPolicy.admit("https://169.254.169.254/x")

    assert {:error, :refused_webhook_private_address, _} =
             AshA2A.Egress.EndpointPolicy.admit("https://[::1]:8443")
  end

  test "positive control: explicit loopback allowance delivers, pinned with original Host header",
       %{port: port} do
    Application.put_env(:ash_a2a, :ocel_egress_policy,
      allow_http: true,
      allow_cidrs: ["127.0.0.0/8", "::1/128"]
    )

    Application.put_env(:ash_a2a, :ocel_ingest_url, "http://localhost:#{port}")
    fire()
    assert_receive {:accepted, data}, 3_000
    assert data =~ "POST /ocel/events"
    assert data =~ "host: localhost:#{port}"
  end
end
