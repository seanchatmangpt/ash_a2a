defmodule AuthorityService.LaneW205HardeningTest do
  # UNVERIFIED: written without an Elixir toolchain; not yet run.
  use ExUnit.Case, async: true
  alias AuthorityService.{ApproverChannel.Mailbox, Listener, TestKit}
  alias Sa2aCrypto.Registry.Static
  import TestKit

  defp frame(term) do
    b = Jason.encode!(term)
    <<byte_size(b)::32, b::binary>>
  end

  defp call(path, term) do
    {:ok, s} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(s, frame(term))
    {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, 2000)
    {:ok, body} = :gen_tcp.recv(s, len, 2000)
    :gen_tcp.close(s)
    Jason.decode!(body)
  end

  describe "approver slot squatting (real unix socket)" do
    setup do
      approvers = Enum.map(~w(alice bob carol), &signer/1)

      {:ok, mb} =
        Mailbox.start_link(
          verify: [
            registry: Static.view(Enum.map(approvers, & &1.record)),
            audience: authority_audience(),
            skew: 0,
            clock: &TestKit.now/0
          ]
        )

      ctx = start_issuer(%{channel: {Mailbox, mb}, approvers: approvers})
      sock = Path.join(ctx.dir, "sq.sock")
      {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock}, mailbox: mb)
      d = digest(effect_bytes(effect()))
      {:ok, Map.merge(ctx, %{sock: sock, d: d})}
    end

    defp approve(ctx, who, approval, gen \\ 9) do
      call(ctx.sock, %{
        "op" => "approve",
        "approver" => who,
        "effect_digest" => ctx.d,
        "generation" => gen,
        "approval" => approval
      })
    end

    test "garbage and foreign approvals are refused and do not consume the slot", ctx do
      alice = signer_named(ctx, "alice")
      good = approval(alice, ctx.d)

      # signature does not belong to the message
      forged = Map.put(good, "message", approval(alice, ctx.d)["message"])
      assert %{"ok" => false, "refusal" => "approval_invalid"} = approve(ctx, "alice", forged)

      # unregistered key
      stranger = signer("mallory")

      assert %{"ok" => false, "refusal" => "approval_invalid"} =
               approve(ctx, "alice", approval(stranger, ctx.d))

      # bob's valid approval offered into alice's slot
      assert %{"ok" => false, "refusal" => "approval_invalid"} =
               approve(ctx, "alice", approval(signer_named(ctx, "bob"), ctx.d))

      # signed for another effect digest / generation than the slot
      other = digest(effect_bytes(effect(%{"amount" => 1})))

      assert %{"ok" => false, "refusal" => "approval_invalid"} =
               approve(ctx, "alice", approval(alice, other))

      assert %{"ok" => false, "refusal" => "approval_invalid"} =
               approve(ctx, "alice", approval(alice, ctx.d, %{"generation" => 8}))

      # the slot is still free: the genuine approval fills it, exactly once
      assert %{"ok" => true} = approve(ctx, "alice", good)

      assert %{"ok" => false, "refusal" => "duplicate_approval"} =
               approve(ctx, "alice", approval(alice, ctx.d))
    end
  end

  describe "mutual TLS listener (real :ssl)" do
    defp pki do
      k = [key: {:namedCurve, :secp256r1}, digest: :sha256]

      :public_key.pkix_test_data(%{
        server_chain: %{root: k, peer: k},
        client_chain: %{root: k, peer: k}
      })
    end

    defp write_pems(dir, conf) do
      sc = conf[:server_config]
      {ktype, kder} = sc[:key]
      pem = fn ders -> :public_key.pem_encode(for c <- ders, do: {:Certificate, c, :not_encrypted}) end

      File.write!(Path.join(dir, "srv.crt"), pem.([sc[:cert] | conf[:client_config][:cacerts]]))
      File.write!(Path.join(dir, "srv.key"), :public_key.pem_encode([{ktype, kder, :not_encrypted}]))
      File.write!(Path.join(dir, "srv.ca"), pem.(sc[:cacerts]))

      [
        certfile: Path.join(dir, "srv.crt"),
        keyfile: Path.join(dir, "srv.key"),
        cacertfile: Path.join(dir, "srv.ca")
      ]
    end

    defp exchange(port, extra) do
      case :ssl.connect(
             ~c"localhost",
             port,
             [:binary, active: false, verify: :verify_none, versions: [:"tlsv1.3"]] ++ extra,
             3000
           ) do
        {:ok, s} ->
          body = Jason.encode!(%{"op" => "noop"})
          _ = :ssl.send(s, <<byte_size(body)::32, body::binary>>)

          res =
            with {:ok, <<len::32>>} <- :ssl.recv(s, 4, 2000),
                 {:ok, b} <- :ssl.recv(s, len, 2000) do
              {:ok, Jason.decode!(b)}
            end

          :ssl.close(s)
          res

        err ->
          err
      end
    end

    test "pinned-CA client is served; a client cert from an unpinned CA is not" do
      ctx = start_issuer()
      conf = pki()
      tls = write_pems(ctx.dir, conf)
      {:ok, l} = Listener.start_link(issuer: ctx.issuer, transport: {:tls, 0, tls})
      port = Listener.port(l)

      assert {:ok, %{"ok" => false, "refusal" => "unknown_op"}} =
               exchange(port, conf[:client_config])

      # a perfectly valid chain, but rooted in a CA the listener does not pin
      rogue = pki()[:client_config]
      refute match?({:ok, _}, exchange(port, rogue))
    end
  end
end
