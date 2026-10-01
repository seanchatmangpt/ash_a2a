defmodule AuthorityService.HardeningCourtsTest do
  @moduledoc """
  v26.9.29 repair courts: each pins a guard that a mutation audit found vacuous.
  """
  use ExUnit.Case, async: true
  alias AuthorityService.{Issuer, Journal, Listener, TestKit}
  alias Sa2aCrypto.Envelope
  import TestKit

  defp issue(ctx, req), do: Issuer.issue(ctx.issuer, req, now: now())
  defp two(ctx, d), do: for(n <- ~w(alice bob), do: approval(signer_named(ctx, n), d))

  describe "unix socket directory guard" do
    test "the socket is never reachable through a group/other-traversable directory, umask 000" do
      dir = tmp_dir("lstdir")
      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")
      paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])

      script = """
      dir = #{inspect(dir)}
      p = Path.join(dir, "x.sock")
      lst = p <> ".lst"
      me = self()
      mode = fn f ->
        case :file.read_file_info(String.to_charlist(f)) do
          {:ok, {:file_info, _, _, _, _, _, _, m, _, _, _, _, _, _}} -> m
          _ -> nil
        end
      end
      poller = spawn(fn ->
        loop = fn loop ->
          # socket present inside the temp dir, THEN look at the dir: the dir must already
          # be closed to group/other, otherwise the socket is reachable through it
          if mode.(Path.join(lst, "s")) != nil do
            m = mode.(lst)
            if m != nil and Bitwise.band(m, 0o077) != 0,
              do: IO.puts("EXPOSED_DIR " <> Integer.to_string(m, 8))
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
      refute out =~ "EXPOSED_DIR"
    end

    test "the temp directory is 0700 when the socket is bound, checked directly under umask 000" do
      # deterministic companion: a listener that stays up leaves no .lst dir, and the
      # transient dir mode is asserted by the polling court above.
      ctx = start_issuer()
      sock = Path.join(ctx.dir, "n.sock")
      {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock})
      refute File.exists?(sock <> ".lst")
    end
  end

  describe "approver registration" do
    test "a registry-valid approver absent from the policy approver list is not counted" do
      approvers = Enum.map(~w(alice bob carol dave), &signer/1)
      ctx = start_issuer(%{approvers: approvers})
      e = effect()
      d = digest(effect_bytes(e))
      apps = [approval(signer_named(ctx, "alice"), d), approval(signer_named(ctx, "dave"), d)]

      assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e, apps))
      assert :approver_not_registered in detail
    end
  end

  describe "revocation epoch pin" do
    defmodule RotatingChannel do
      @moduledoc false
      @behaviour AuthorityService.ApproverChannel
      def solicit(%{agent: agent, rotate_kid: kid, bob: bob}, "bob", _req) do
        TestKit.LiveRegistry.rotate(agent, kid)
        {:ok, bob}
      end

      def solicit(_, _, _), do: {:error, :no_response}
    end

    test "a key rotated to a new epoch (still active) mid-issuance refuses" do
      approvers = Enum.map(~w(alice bob carol), &signer/1)
      {:ok, agent} = TestKit.LiveRegistry.start(Enum.map(approvers, & &1.record))
      alice = Enum.find(approvers, &(&1.custodian == "alice"))
      bob = Enum.find(approvers, &(&1.custodian == "bob"))
      e = effect()
      d = digest(effect_bytes(e))
      a_bob = approval(bob, d)
      {:ok, env} = Envelope.decode(Jcs.encode(a_bob["envelope"]))
      {:ok, msg} = Base.url_decode64(a_bob["message"], padding: false)

      channel =
        {RotatingChannel,
         %{agent: agent, rotate_kid: alice.kid, bob: %{envelope: env, message: msg}}}

      ctx =
        start_issuer(%{
          approvers: approvers,
          registry: TestKit.LiveRegistry.view(agent),
          channel: channel
        })

      assert {:refused, :approver_revoked_during_issuance, _} =
               issue(ctx, request(e, [approval(alice, d)]))
    end
  end

  describe "journal failure is fail-closed" do
    test "an append that cannot persist stops the issuer; restart still refuses the reissue" do
      ctx = start_issuer()
      Process.flag(:trap_exit, true)
      ref = Process.monitor(ctx.issuer)
      # block the anchor's tmp file: the append fails after the journal line is written
      tmp = ctx.config.anchor_path <> ".tmp"
      File.mkdir_p!(tmp)
      e = effect()
      req = request(e, two(ctx, digest(effect_bytes(e))))

      # the caller sees the typed refusal or the server's fail-closed exit, never an issuance
      result =
        try do
          issue(ctx, req)
        catch
          :exit, e -> e
        end

      case result do
        {:refused, :journal_failed, _} -> :ok
        {{:journal_failed, _}, _} -> :ok
        {:journal_failed, _} -> :ok
        other -> flunk("expected fail-closed, got #{inspect(other)}")
      end

      assert_receive {:DOWN, ^ref, :process, _, :journal_failed}, 2_000
      refute Process.alive?(ctx.issuer)

      File.rm_rf!(tmp)
      assert {:ok, pid} = Issuer.start_link(config: ctx.config, name: nil)
      assert {:refused, :already_issued, _} = Issuer.issue(pid, req, now: now())
    end
  end

  describe "journal anchor and line strictness" do
    test "an unreadable (non-enoent) anchor is anchor_corrupt, not accepted" do
      ctx = start_issuer()
      e = effect()
      assert {:ok, _} = issue(ctx, request(e, two(ctx, digest(effect_bytes(e)))))
      GenServer.stop(ctx.issuer)
      File.rm!(ctx.config.anchor_path)
      File.mkdir_p!(ctx.config.anchor_path)
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_anchor, :anchor_corrupt}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end

    test "a journal line with a duplicate key is corrupt even when last-wins would verify" do
      ctx = start_issuer()
      assert {:ok, _} = issue(ctx, request(notify(), []))
      GenServer.stop(ctx.issuer)
      [line] = File.read!(ctx.config.journal_path) |> String.split("\n", trim: true)
      assert String.starts_with?(line, "{")
      # a duplicated `seq` with the same value: any last/first-wins parser accepts the chain
      dup = "{\"seq\":1," <> binary_part(line, 1, byte_size(line) - 1)
      assert {:ok, %{"seq" => 1}} = Jason.decode(dup)
      File.write!(ctx.config.journal_path, dup <> "\n")
      Process.flag(:trap_exit, true)

      assert {:error, {:journal_corrupt, :duplicate_key}} =
               Issuer.start_link(config: ctx.config, name: nil)
    end
  end

  describe "effect bytes" do
    defp raw_request(bytes) do
      request(notify(), [], %{
        "effect" => Base.url_encode64(bytes, padding: false),
        "effect_digest" => digest(bytes)
      })
    end

    test "a valid but non-canonical effect encoding is refused" do
      ctx = start_issuer()
      canonical = effect_bytes(notify())
      pretty = String.replace(canonical, ",", ", ")
      assert pretty != canonical
      assert {:refused, :non_canonical_effect, _} = issue(ctx, raw_request(pretty))
      assert {:ok, _} = issue(ctx, raw_request(canonical))
    end

    test "an effect with a duplicate key is malformed (not merely non-canonical)" do
      ctx = start_issuer()
      canonical = effect_bytes(notify())
      dup = "{\"amount\":1," <> binary_part(canonical, 1, byte_size(canonical) - 1)
      assert {:ok, _} = Jason.decode(dup)
      assert {:refused, :malformed_effect, _} = issue(ctx, raw_request(dup))
    end
  end

  describe "approval bindings" do
    test "an approval signed for another generation is not counted" do
      ctx = start_issuer()
      e = effect()
      d = digest(effect_bytes(e))

      apps = [
        approval(signer_named(ctx, "alice"), d, %{"generation" => 8}),
        approval(signer_named(ctx, "bob"), d)
      ]

      assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e, apps))
      assert :approval_generation_mismatch in detail
    end

    test "an approval signed for another principal is not counted" do
      ctx = start_issuer()
      e = effect()
      d = digest(effect_bytes(e))

      apps = [
        approval(signer_named(ctx, "alice"), d, %{"principal" => "agent:mallory"}),
        approval(signer_named(ctx, "bob"), d)
      ]

      assert {:refused, :insufficient_approvals, detail} = issue(ctx, request(e, apps))
      assert :approval_principal_mismatch in detail
    end
  end

  describe "request bounds" do
    test "more approvals than policy.max_approvals is a malformed request" do
      ctx = start_issuer()
      max = ctx.config.policy.max_approvals

      assert {:refused, :malformed_request, _} =
               issue(ctx, request(notify(), List.duplicate(%{}, max + 1)))

      assert {:ok, _} = issue(ctx, request(notify(%{"idem" => "b"}), List.duplicate(%{}, max)))
    end
  end

  describe "approver nonce reuse across issuances" do
    test "an approver nonce consumed by one issuance is refused on a different effect, across restart" do
      ctx = start_issuer()
      n1 = nonce()
      e1 = effect(%{"idem" => "one"})
      d1 = digest(effect_bytes(e1))

      apps1 = [
        approval(signer_named(ctx, "alice"), d1, %{"nonce" => n1}),
        approval(signer_named(ctx, "bob"), d1)
      ]

      assert {:ok, _} = issue(ctx, request(e1, apps1))

      {:ok, pid} =
        (fn ->
           GenServer.stop(ctx.issuer)
           Issuer.start_link(config: ctx.config, name: nil)
         end).()

      e2 = effect(%{"idem" => "two"})
      d2 = digest(effect_bytes(e2))

      apps2 = [
        approval(signer_named(ctx, "alice"), d2, %{"nonce" => n1}),
        approval(signer_named(ctx, "bob"), d2)
      ]

      assert {:refused, :insufficient_approvals, detail} =
               Issuer.issue(pid, request(e2, apps2), now: now())

      assert :approval_replayed in detail
      {:ok, j} = Journal.open(ctx.config.journal_path, ctx.config.anchor_path)
      refute Journal.issued?(j, d2, 9)
    end
  end
end
