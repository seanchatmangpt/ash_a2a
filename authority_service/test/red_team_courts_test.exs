defmodule AuthorityService.RedTeamCourtsTest do
  @moduledoc """
  Courts for the v26.9.29 red-team defects: B1 cross-audience issuance, T4 revocation race,
  B2 journal truncation, B3 tier confusion, plus replay-across-restart and wire strictness.
  """
  use ExUnit.Case, async: true
  import Bitwise
  alias AuthorityService.{Issuer, Journal, Listener, TestKit}
  alias Sa2aCrypto.Envelope
  import TestKit

  defp issue(ctx, req), do: Issuer.issue(ctx.issuer, req, now: now())
  defp two(ctx, d), do: for(n <- ~w(alice bob), do: approval(signer_named(ctx, n), d))

  defp restart(ctx) do
    GenServer.stop(ctx.issuer)
    Issuer.start_link(config: ctx.config, name: nil)
  end

  describe "B1 cross-audience" do
    test "a request naming another audience is refused; the certificate audience is server-side" do
      ctx = start_issuer()
      e = notify()

      assert {:refused, :audience_not_registered, _} =
               issue(ctx, request(e, [], %{"audience" => "actuator:other"}))

      # naming nothing is fine: the audience comes from the registered actuator identity
      req = request(e, []) |> Map.delete("audience")
      assert {:ok, cert} = issue(ctx, req)
      {:ok, m} = Base.url_decode64(cert["message"], padding: false)
      {:ok, msg} = Sa2aCrypto.SignedMessage.parse(m)
      assert msg["audience"] == actuator()
      assert cert["envelope"]["audience"] == actuator()
      # nothing was journaled for the refused request
      assert {:ok, _} = issue(ctx, request(notify(%{"idem" => "2"}), []))
    end

    test "duplicate audience keys on the wire are refused, not last-wins" do
      ctx = start_issuer()
      sock = Path.join(ctx.dir, "d.sock")
      {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock})
      body = Jcs.encode(Map.put(request(notify(), []), "op", "issue"))

      dup =
        String.replace(
          body,
          ~s("audience":"actuator:test"),
          ~s("audience":"actuator:test","audience":"actuator:evil")
        )

      assert dup != body

      {:ok, s} = :gen_tcp.connect({:local, sock}, 0, [:binary, active: false, packet: :raw])
      :ok = :gen_tcp.send(s, <<byte_size(dup)::32, dup::binary>>)
      {:ok, <<len::32>>} = :gen_tcp.recv(s, 4, 2000)
      {:ok, resp} = :gen_tcp.recv(s, len, 2000)
      assert %{"ok" => false, "refusal" => "malformed_request"} = Jason.decode!(resp)
    end

    test "no registered actuator audience: everything refused (fail closed)" do
      base = start_issuer()
      ctx = start_issuer(%{dir: nil})
      GenServer.stop(ctx.issuer)
      cfg = %{ctx.config | actuator_audience: nil}
      {:ok, pid} = Issuer.start_link(config: cfg, name: nil)

      assert {:refused, :audience_unconfigured, _} =
               Issuer.issue(pid, request(notify(), []), now: now())

      assert base.issuer != pid
    end
  end

  describe "T4 revocation race" do
    defmodule RevokingChannel do
      @moduledoc false
      @behaviour AuthorityService.ApproverChannel
      # Solicited for bob: at that instant alice's key is revoked in the live registry,
      # then bob's (valid) approval is returned.
      def solicit(%{agent: agent, revoke_kid: kid, bob: bob}, "bob", _req) do
        TestKit.LiveRegistry.revoke(agent, kid)
        {:ok, bob}
      end

      def solicit(_, _, _), do: {:error, :no_response}
    end

    defp live_ctx(channel_fun) do
      approvers = Enum.map(~w(alice bob carol), &signer/1)
      {:ok, agent} = TestKit.LiveRegistry.start(Enum.map(approvers, & &1.record))
      base = %{approvers: approvers, registry: TestKit.LiveRegistry.view(agent)}
      alice = Enum.find(approvers, &(&1.custodian == "alice"))
      bob = Enum.find(approvers, &(&1.custodian == "bob"))
      e = effect()
      d = digest(effect_bytes(e))
      a_bob = approval(bob, d)
      {:ok, env} = Envelope.decode(Jcs.encode(a_bob["envelope"]))
      {:ok, msg} = Base.url_decode64(a_bob["message"], padding: false)

      channel =
        channel_fun.(%{agent: agent, revoke_kid: alice.kid, bob: %{envelope: env, message: msg}})

      ctx = start_issuer(Map.put(base, :channel, channel))
      {ctx, agent, alice, e, d}
    end

    test "a revocation landing between approval check and issuance refuses" do
      {ctx, _agent, alice, e, d} = live_ctx(&{RevokingChannel, &1})
      req = request(e, [approval(alice, d)])
      assert {:refused, :approver_revoked_during_issuance, _} = issue(ctx, req)
      # nothing was journaled: after restart the (digest, generation) is still unissued
      {:ok, j} = Journal.open(ctx.config.journal_path, ctx.config.anchor_path)
      refute Journal.issued?(j, d, 9)
    end

    test "a revocation before the request is refused at verification" do
      {ctx, agent, alice, e, d} = live_ctx(&{RevokingChannel, &1})
      TestKit.LiveRegistry.revoke(agent, alice.kid)

      assert {:refused, :insufficient_approvals, detail} =
               issue(ctx, request(e, [approval(alice, d)]))

      assert :approval_key_compromised in detail
    end

    test "a registry given as a function is resolved inside the issuance step" do
      approvers = Enum.map(~w(alice bob carol), &signer/1)
      {:ok, agent} = TestKit.LiveRegistry.start(Enum.map(approvers, & &1.record))
      me = self()

      fun = fn ->
        send(me, :resolved)
        TestKit.LiveRegistry.view(agent)
      end

      ctx = start_issuer(%{approvers: approvers, registry: fun})
      refute_received :resolved
      e = notify()
      assert {:ok, _} = issue(ctx, request(e, []))
      assert_received :resolved
    end
  end

  describe "B2 journal truncation" do
    defp two_issued do
      ctx = start_issuer()

      for idem <- ~w(a b) do
        e = effect(%{"idem" => idem})
        assert {:ok, _} = issue(ctx, request(e, two(ctx, digest(effect_bytes(e)))))
      end

      ctx
    end

    test "dropping the last journal entry refuses to start" do
      ctx = two_issued()
      GenServer.stop(ctx.issuer)
      [first | _] = File.read!(ctx.config.journal_path) |> String.split("\n", trim: true)
      File.write!(ctx.config.journal_path, first <> "\n")
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :journal_truncated}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "truncating the journal to empty refuses to start (no re-issue)" do
      ctx = two_issued()
      GenServer.stop(ctx.issuer)
      File.write!(ctx.config.journal_path, "")
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :journal_truncated}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "a non-empty journal with no anchor refuses to start" do
      ctx = two_issued()
      GenServer.stop(ctx.issuer)
      File.rm!(ctx.config.anchor_path)
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :anchor_missing}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "a journal whose chain differs at the anchored seq refuses to start" do
      ctx = two_issued()
      GenServer.stop(ctx.issuer)
      other = two_issued()
      GenServer.stop(other.issuer)
      File.cp!(other.config.journal_path, ctx.config.journal_path)
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :anchor_mismatch}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "a malformed anchor refuses to start" do
      ctx = two_issued()
      GenServer.stop(ctx.issuer)
      File.write!(ctx.config.anchor_path, "garbage")
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :anchor_corrupt}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "journal one entry ahead of the anchor (crash between the two writes) is accepted" do
      ctx = start_issuer()
      e1 = effect(%{"idem" => "a"})
      assert {:ok, _} = issue(ctx, request(e1, two(ctx, digest(effect_bytes(e1)))))
      old_anchor = File.read!(ctx.config.anchor_path)
      e2 = effect(%{"idem" => "b"})
      assert {:ok, _} = issue(ctx, request(e2, two(ctx, digest(effect_bytes(e2)))))
      GenServer.stop(ctx.issuer)
      File.write!(ctx.config.anchor_path, old_anchor)
      assert {:ok, pid} = Issuer.start_link(config: ctx.config, name: nil)

      assert {:refused, :already_issued, _} =
               Issuer.issue(pid, request(e2, two(ctx, digest(effect_bytes(e2)))), now: now())
    end

    test "an intact journal restarts and the anchor tracks every append" do
      ctx = two_issued()
      assert %{"seq" => 2} = Jason.decode!(File.read!(ctx.config.anchor_path))
      assert {:ok, pid} = restart(ctx)
      assert is_pid(pid)
    end
  end

  describe "replay across restart" do
    test "an issued request and its consumed approvals stay consumed after restart" do
      ctx = start_issuer()
      e = effect()
      d = digest(effect_bytes(e))
      apps = two(ctx, d)
      assert {:ok, _} = issue(ctx, request(e, apps))
      {:ok, pid} = restart(ctx)
      assert {:refused, :already_issued, _} = Issuer.issue(pid, request(e, apps), now: now())
      {:ok, j} = Journal.open(ctx.config.journal_path, ctx.config.anchor_path)

      for a <- apps do
        {:ok, env} = Envelope.decode(Jcs.encode(a["envelope"]))
        assert Journal.approval_seen?(j, env.kid, env.nonce)
      end
    end
  end

  describe "B3 tier confusion" do
    test "a low declared amount never lowers the class tier (authority shape)" do
      ctx = start_issuer()

      for amount <- [0, 1, 5_000] do
        e = effect(%{"amount" => amount, "idem" => "t#{amount}"})
        assert {:refused, :insufficient_approvals, []} = issue(ctx, request(e, []))
      end

      # a requester-side amount outside the signed effect is ignored too
      e = effect()

      assert {:refused, :insufficient_approvals, []} =
               issue(ctx, request(e, [], %{"amount" => 0}))
    end

    test "a class with an automated amount tier still requires its most restrictive k" do
      ctx = start_issuer()
      e = effect(%{"effect_class" => "tiered", "amount" => 1})
      assert {:refused, :insufficient_approvals, []} = issue(ctx, request(e, []))
      assert {:ok, _} = issue(ctx, request(e, two(ctx, digest(effect_bytes(e)))))
    end

    test "actuator-shaped effects (no amount) get the class tier, not the lowest tier" do
      ctx = start_issuer()

      e = %{
        "principal" => "agent:alice",
        "effect_type" => "pay",
        "consequence_class" => "tiered",
        "params" => %{"x" => 1}
      }

      assert {:refused, :insufficient_approvals, []} = issue(ctx, request(e, []))
    end

    test "only a class the policy declares k=0 issues without approvals" do
      ctx = start_issuer()
      assert {:ok, _} = issue(ctx, request(notify(), []))
    end
  end

  describe "unix socket exposure" do
    test "the socket is never group/other accessible at any instant of listening, umask 000" do
      dir = tmp_dir("sockmode")
      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")
      paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

      script = """
      dir = #{inspect(dir)}
      p = Path.join(dir, "x.sock")
      me = self()
      poller = spawn(fn ->
        loop = fn loop ->
          case :file.read_file_info(String.to_charlist(p)) do
            {:ok, {:file_info, _, :other, _, _, _, _, m, _, _, _, _, _, _}} when Bitwise.band(m, 0o007) != 0 ->
              IO.puts("EXPOSED " <> Integer.to_string(m, 8))
            _ -> :ok
          end
          receive do :stop -> send(me, :stopped) after 0 -> loop.(loop) end
        end
        loop.(loop)
      end)
      for _ <- 1..400 do
        {:ok, l} = AuthorityService.Listener.start_link(issuer: :none, transport: {:unix, p})
        Process.unlink(l)
        GenServer.stop(l)
      end
      send(poller, :stop)
      receive do :stopped -> :ok end
      IO.puts("DONE")
      """

      {out, 0} =
        System.cmd("sh", ["-c", ~s(umask 000; exec "$0" "$@"), elixir] ++ paths ++ ["-e", script],
          stderr_to_stdout: true
        )

      assert out =~ "DONE"
      refute out =~ "EXPOSED"
    end

    test "the bound socket has no other-access bits" do
      ctx = start_issuer()
      sock = Path.join(ctx.dir, "m.sock")
      {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock})
      assert (File.stat!(sock).mode &&& 0o007) == 0
      refute File.exists?(sock <> ".lst")
    end
  end
end
