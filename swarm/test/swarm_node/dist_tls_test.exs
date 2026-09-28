defmodule SwarmNode.DistTlsTest do
  @moduledoc """
  DEP-07 / SEC-10: the shipped `rel/overlays/ssl_dist.conf` really makes two
  BEAM nodes speak distribution over mutually-authenticated TLS.

  Real collaborators only: `openssl` generates a throwaway cluster CA plus leaf
  certificates in a temp dir, the shipped optfile is rendered with those paths
  (the ONLY change: `/etc/ash_a2a/dist` -> the temp dir), and real `erl` OS
  processes are started with `-proto_dist inet_tls -ssl_dist_optfile`.
  Positive control: same-CA TLS nodes connect. Negative controls: a node with
  a certificate from a different CA, a TLS node that trusts the CA but presents
  no certificate (fail_if_no_peer_cert), and a cleartext node cannot connect.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @conf Path.expand("../../rel/overlays/ssl_dist.conf", __DIR__)

  setup_all do
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    dir = Path.join(System.tmp_dir!(), "swarm_dist_tls_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    good = make_ca_and_leaf!(Path.join(dir, "good"))
    rogue = make_ca_and_leaf!(Path.join(dir, "rogue"))
    # A rogue node that presents a leaf from ANOTHER CA but trusts the good CA.
    File.cp!(Path.join(good, "ca.crt"), Path.join(rogue, "ca.crt"))

    # A TLS client that trusts the cluster CA but presents NO certificate.
    certless = Path.join(dir, "certless")
    File.mkdir_p!(certless)
    File.cp!(Path.join(good, "ca.crt"), Path.join(certless, "ca.crt"))

    certless_conf = Path.join(certless, "ssl_dist.conf")

    File.write!(certless_conf, """
    [{server, [{cacertfile, "#{certless}/ca.crt"}, {verify, verify_peer}]},
     {client, [{cacertfile, "#{certless}/ca.crt"}, {verify, verify_peer},
               {server_name_indication, disable}]}].
    """)

    %{good: render_conf!(good), rogue: render_conf!(rogue), certless: certless_conf}
  end

  defp openssl!(args, cd) do
    {out, status} = System.cmd("openssl", args, cd: cd, stderr_to_stdout: true)
    assert status == 0, "openssl #{Enum.join(args, " ")} failed: #{out}"
  end

  defp make_ca_and_leaf!(dir) do
    File.mkdir_p!(dir)

    openssl!(
      ~w(req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=ca -keyout ca.key -out ca.crt),
      dir
    )

    openssl!(
      ~w(req -newkey rsa:2048 -nodes -subj /CN=swarm_node -keyout tls.key -out tls.csr),
      dir
    )

    openssl!(
      ~w(x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -out tls.crt),
      dir
    )

    dir
  end

  defp render_conf!(cert_dir) do
    rendered = @conf |> File.read!() |> String.replace("/etc/ash_a2a/dist", cert_dir)
    assert rendered != File.read!(@conf), "optfile must reference /etc/ash_a2a/dist"
    path = Path.join(cert_dir, "ssl_dist.conf")
    File.write!(path, rendered)
    path
  end

  defp host, do: :inet.gethostname() |> elem(1) |> List.to_string()

  defp tls_args(nil), do: []
  defp tls_args(conf), do: ["-proto_dist", "inet_tls", "-ssl_dist_optfile", conf]

  # A real listening node: an `erl` OS process that stays up for 60 s.
  defp start_listener(name, conf) do
    erl = System.find_executable("erl")

    port =
      Port.open({:spawn_executable, erl}, [
        :binary,
        :exit_status,
        args:
          ["-noshell", "-sname", name, "-setcookie", "tlscookie"] ++
            tls_args(conf) ++ ["-eval", "timer:sleep(60000), halt()."]
      ])

    wait_registered!(name, 50)
    port
  end

  defp wait_registered!(name, 0), do: flunk("node #{name} never registered with epmd")

  defp wait_registered!(name, tries) do
    {:ok, names} = :erl_epmd.names()

    if Enum.any?(names, fn {n, _} -> List.to_string(n) == name end) do
      :ok
    else
      Process.sleep(100)
      wait_registered!(name, tries - 1)
    end
  end

  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)])
      _ -> :ok
    end
  end

  # A real client node: pings the listener and prints pong/pang.
  defp ping(target, conf) do
    name = "tls_client_#{System.unique_integer([:positive])}"

    {out, _} =
      System.cmd(
        "erl",
        ["-noshell", "-sname", name, "-setcookie", "tlscookie"] ++
          tls_args(conf) ++
          [
            "-eval",
            "io:format(\"~p~n\", [net_adm:ping('#{target}@#{host()}')]), halt()."
          ],
        stderr_to_stdout: true
      )

    cond do
      out =~ "pong" -> :pong
      out =~ "pang" -> :pang
      true -> {:other, out}
    end
  end

  test "same-CA TLS nodes connect; foreign-CA, certificate-less and cleartext nodes are refused",
       %{good: good, rogue: rogue, certless: certless} do
    name = "tls_server_#{System.unique_integer([:positive])}"
    listener = start_listener(name, good)

    try do
      assert ping(name, good) == :pong
      assert ping(name, rogue) == :pang
      assert ping(name, certless) == :pang
      assert ping(name, nil) == :pang
    after
      stop(listener)
    end
  end
end
