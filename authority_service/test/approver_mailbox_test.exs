defmodule AuthorityService.ApproverMailboxTest do
  use ExUnit.Case, async: true
  alias AuthorityService.{ApproverChannel.Mailbox, Listener, TestKit}
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

  setup do
    {:ok, mb} = Mailbox.start_link()
    ctx = start_issuer(%{channel: {Mailbox, mb}})
    sock = Path.join(ctx.dir, "m.sock")
    {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock}, mailbox: mb)
    e = effect()
    d = digest(effect_bytes(e))
    {:ok, Map.merge(ctx, %{sock: sock, e: e, d: d})}
  end

  defp approve(ctx, who, approval, as \\ nil) do
    call(ctx.sock, %{
      "op" => "approve",
      "approver" => as || who,
      "effect_digest" => ctx.d,
      "generation" => 9,
      "approval" => approval
    })
  end

  defp issue(ctx),
    do: call(ctx.sock, Map.put(request(ctx.e), "op", "issue"))

  test "k=2 is collected over the wire from two distinct approvers", ctx do
    assert %{"ok" => false, "refusal" => "insufficient_approvals"} = issue(ctx)

    assert %{"ok" => true} = approve(ctx, "alice", approval(signer_named(ctx, "alice"), ctx.d))
    # one approval of two required: still refused
    assert %{"ok" => false, "refusal" => "insufficient_approvals"} = issue(ctx)

    assert %{"ok" => true} = approve(ctx, "bob", approval(signer_named(ctx, "bob"), ctx.d))
    assert %{"ok" => true, "certificate" => %{"envelope" => _}} = issue(ctx)
    # single issuance: the consumed approvals cannot mint a second certificate
    assert %{"ok" => false, "refusal" => "already_issued"} = issue(ctx)
  end

  test "duplicate and replayed approvals are refused", ctx do
    a = approval(signer_named(ctx, "alice"), ctx.d)
    assert %{"ok" => true} = approve(ctx, "alice", a)
    # same slot
    assert %{"ok" => false, "refusal" => "duplicate_approval"} = approve(ctx, "alice", a)
    # same (kid, nonce) replayed under another approver's slot
    assert %{"ok" => false, "refusal" => "duplicate_approval"} = approve(ctx, "alice", a, "bob")
    # slot is first-wins: a fresh approval cannot overwrite it
    a2 = approval(signer_named(ctx, "alice"), ctx.d)
    assert %{"ok" => false, "refusal" => "duplicate_approval"} = approve(ctx, "alice", a2)
  end

  test "one custodian filling two slots counts once", ctx do
    alice = signer_named(ctx, "alice")
    assert %{"ok" => true} = approve(ctx, "alice", approval(alice, ctx.d))
    assert %{"ok" => true} = approve(ctx, "alice", approval(alice, ctx.d), "bob")

    assert %{"ok" => false, "refusal" => "insufficient_approvals", "detail" => detail} =
             issue(ctx)

    assert "duplicate_custodian" in detail
  end

  test "an approval over another effect or a malformed approval does not issue", ctx do
    other = digest(effect_bytes(effect(%{"amount" => 1})))
    assert %{"ok" => true} = approve(ctx, "alice", approval(signer_named(ctx, "alice"), other))
    assert %{"ok" => true} = approve(ctx, "bob", approval(signer_named(ctx, "bob"), other))

    assert %{"ok" => false, "refusal" => "insufficient_approvals", "detail" => detail} =
             issue(ctx)

    assert "approval_effect_mismatch" in detail

    assert %{"ok" => false, "refusal" => "malformed_approval"} =
             approve(ctx, "carol", %{"envelope" => "x", "message" => 1})

    assert %{"ok" => false, "refusal" => "malformed_request"} =
             call(ctx.sock, %{"op" => "approve"})
  end

  test "without a mailbox the approve op does not exist" do
    ctx = start_issuer()
    sock = Path.join(ctx.dir, "n.sock")
    {:ok, _} = Listener.start_link(issuer: ctx.issuer, transport: {:unix, sock})
    assert %{"ok" => false, "refusal" => "unknown_op"} = call(sock, %{"op" => "approve"})
  end
end
