defmodule AshA2A.EmailReplyTokenMacTest do
  @moduledoc """
  Reply tokens are keyed MACs. Real Plug + real Brief + real TokenLedger; dispatch is a
  hand-written recording function (the governed agent is infeasible in-process).
  Serial: some cases change the application's `:email_token_key`.
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshA2A.Email.{Brief, TokenLedger}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"
  @key1 String.duplicate("k", 32)
  @key2 String.duplicate("m", 40)
  @now 1_800_000_000

  setup do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {:ok, ledger} = TokenLedger.start_link([])
    {:ok, rec: rec, ledger: ledger}
  end

  defp brief(over \\ %{}) do
    Map.merge(
      %{
        title: "Daily",
        date: "2026-11-13",
        sections: [],
        approver: "principal:approver",
        actions: [%{n: 1, summary: "Deploy", action: :deploy, args: %{}, graph_digest: @digest}]
      },
      over
    )
  end

  defp bare(b),
    do:
      b
      |> Brief.render(key: @key1)
      |> Map.fetch!(:message_id)
      |> String.trim("<")
      |> String.trim(">")

  defp opts(rec, ledger, b, over \\ []) do
    mid = bare(b)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      webhook: :trusted_ingress,
      token_ledger: ledger,
      token_key: @key1,
      now: @now,
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest}}
        _ -> :error
      end,
      dispatch: fn p, a ->
        Agent.update(rec, &(&1 ++ [{p.id, a.n}]))
        {:ok, :done}
      end
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp req(b, token, mid \\ nil) do
    params = %{
      "from" => @sender,
      "in_reply_to" => bare(b),
      "text" => "Approve 1.",
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => %{"1" => token}
    }

    params = if mid, do: Map.put(params, "message_id", mid), else: params
    conn(:post, "/v1/email:ingest", params)
  end

  defp err(conn), do: Jason.decode!(conn.resp_body)["error"]
  defp dispatched(rec), do: Agent.get(rec, & &1)

  test "token is 49 chars of base64url and verifies", %{rec: rec, ledger: ledger} do
    b = brief()
    t = Brief.reply_token(b, 1, key: @key1)
    assert byte_size(t) == 49
    assert t =~ ~r/\A[A-Za-z0-9_-]{49}\z/
    c = EmailPlug.call(req(b, t), opts(rec, ledger, b))
    assert c.status == 200
    assert dispatched(rec) == [{"principal:approver", 1}]
  end

  test "forged token computed from the public content is refused 403", %{rec: rec, ledger: ledger} do
    b = brief()
    # the pre-change unkeyed derivation: 16 hex of a sha256 anyone can compute
    legacy =
      :crypto.hash(:sha256, Brief.brief_digest(b))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    c = EmailPlug.call(req(b, legacy), opts(rec, ledger, b))
    assert {c.status, err(c)} == {403, "invalid_reply_token"}
    assert dispatched(rec) == []
  end

  test "legacy unkeyed token (16 hex) is refused", %{rec: rec, ledger: ledger} do
    b = brief()
    c = EmailPlug.call(req(b, "0123456789abcdef"), opts(rec, ledger, b))
    assert {c.status, err(c)} == {403, "invalid_reply_token"}
    assert dispatched(rec) == []
  end

  test "token minted for another approver is refused", %{rec: rec, ledger: ledger} do
    b = brief()
    other = Brief.reply_token(brief(%{approver: "principal:other"}), 1, key: @key1)
    c = EmailPlug.call(req(b, other), opts(rec, ledger, b))
    assert {c.status, err(c)} == {403, "invalid_reply_token"}
    assert dispatched(rec) == []
  end

  test "token after expiry is refused, before expiry accepted", %{rec: rec, ledger: ledger} do
    b = brief(%{expires_at: @now + 10})
    t = Brief.reply_token(b, 1, key: @key1)

    late = opts(rec, ledger, b, now: @now + 11)
    c = EmailPlug.call(req(b, t), late)
    assert {c.status, err(c)} == {403, "reply_token_expired"}
    assert dispatched(rec) == []

    assert EmailPlug.call(req(b, t), opts(rec, ledger, b, now: @now + 10)).status == 200
  end

  test "expiry cannot be extended by editing the brief", %{rec: rec, ledger: ledger} do
    b = brief(%{expires_at: @now + 10})
    t = Brief.reply_token(b, 1, key: @key1)
    extended = brief(%{expires_at: @now + 99_999})
    c = EmailPlug.call(req(extended, t), opts(rec, ledger, extended, now: @now + 11))
    assert {c.status, err(c)} == {403, "invalid_reply_token"}
  end

  test "replay of a spent token under a new message id is refused 409", %{
    rec: rec,
    ledger: ledger
  } do
    b = brief()
    t = Brief.reply_token(b, 1, key: @key1)
    o = opts(rec, ledger, b)
    assert EmailPlug.call(req(b, t, "m1"), o).status == 200
    c = EmailPlug.call(req(b, t, "m2"), o)
    assert {c.status, err(c)} == {409, "already_consumed"}
    assert dispatched(rec) == [{"principal:approver", 1}]
  end

  test "token minted under a wrong key is refused", %{rec: rec, ledger: ledger} do
    b = brief()
    t = Brief.reply_token(b, 1, key: @key2)
    c = EmailPlug.call(req(b, t), opts(rec, ledger, b))
    assert {c.status, err(c)} == {403, "invalid_reply_token"}
    assert dispatched(rec) == []
  end

  test "same-length token with a flipped MAC byte is refused", %{rec: rec, ledger: ledger} do
    b = brief()
    t = Brief.reply_token(b, 1, key: @key1)
    {head, last} = String.split_at(t, -1)
    bad = head <> if(last == "A", do: "B", else: "A")
    c = EmailPlug.call(req(b, bad), opts(rec, ledger, b))
    assert c.status == 403
  end

  test "rotation: previous key still verifies, then removed is refused", %{
    rec: rec,
    ledger: ledger
  } do
    b = brief()
    old = Brief.reply_token(b, 1, key: @key1)

    rotated = opts(rec, ledger, b, token_key: @key2, token_key_previous: @key1)
    assert EmailPlug.call(req(b, old), rotated).status == 200

    {:ok, ledger2} = TokenLedger.start_link([])
    removed = opts(rec, ledger2, b, token_key: @key2)
    c = EmailPlug.call(req(b, old), removed)
    assert {c.status, err(c)} == {403, "invalid_reply_token"}

    # new tokens carry the new key id
    fresh = Brief.reply_token(b, 1, key: @key2)
    refute binary_part(fresh, 0, 6) == binary_part(old, 0, 6)
    assert EmailPlug.call(req(b, fresh), removed).status == 200
  end

  describe "key configuration" do
    setup do
      prev = Application.get_env(:ash_a2a, :email_token_key)
      on_exit(fn -> Application.put_env(:ash_a2a, :email_token_key, prev) end)
      :ok
    end

    test "unset key: plug refuses 503 email_token_key_missing and the builder raises", %{
      rec: rec,
      ledger: ledger
    } do
      Application.delete_env(:ash_a2a, :email_token_key)
      refute Brief.token_key_configured?()
      b = brief()
      o = opts(rec, ledger, b, token_key: nil)
      c = EmailPlug.call(req(b, "x"), o)
      assert {c.status, err(c)} == {503, "email_token_key_missing"}

      assert_raise Brief.TokenKeyError, ~r/email_token_key_missing/, fn -> Brief.render(b) end
      assert {:error, :email_token_key_missing} = Brief.verify_reply_token(b, 1, "x")
    end

    test "short key is refused with a typed error", %{rec: rec, ledger: ledger} do
      Application.put_env(:ash_a2a, :email_token_key, "too-short")
      refute Brief.token_key_configured?()
      assert {:error, :email_token_key_too_short} = Brief.keyring([])
      b = brief()
      c = EmailPlug.call(req(b, "x"), opts(rec, ledger, b, token_key: nil))
      assert {c.status, err(c)} == {503, "email_token_key_too_short"}
    end

    test "configured key is reported by the oracle" do
      Application.put_env(:ash_a2a, :email_token_key, @key1)
      assert Brief.token_key_configured?()
    end
  end
end
