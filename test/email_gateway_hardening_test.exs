defmodule AshA2A.EmailGatewayHardeningTest do
  @moduledoc """
  L12: refusals of `AshA2A.Email.Plug` driven through `Plug.Test` with the real Brief,
  Inbound, ReplyIntent, Webhook and TokenLedger. Dispatch and reply_sender are hand-written
  recording functions.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshA2A.Email.{Brief, TokenLedger}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"
  @secret "0123456789abcdef-secret"

  setup do
    {:ok, rec} = Agent.start_link(fn -> %{dispatched: [], replies: []} end)
    {:ok, ledger} = TokenLedger.start_link()
    {:ok, rec: rec, ledger: ledger}
  end

  defp brief(extra \\ %{}) do
    Map.merge(
      %{
        title: "Daily",
        date: "2026-11-13",
        sections: [],
        actions: [
          %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest}
        ]
      },
      extra
    )
  end

  defp bare(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp opts(rec, ledger, over \\ []) do
    b = Keyword.get(over, :brief, brief())
    mid = bare(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      webhook: {:workspace, token: @secret},
      token_ledger: ledger,
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest}}
        _ -> :error
      end,
      dispatch: fn principal, action ->
        Agent.update(rec, &Map.update!(&1, :dispatched, fn l -> l ++ [{principal, action.n}] end))
        {:ok, :done}
      end,
      reply_sender: fn to, subject, text ->
        Agent.update(rec, &Map.update!(&1, :replies, fn l -> l ++ [{to, subject, text}] end))
      end
    ]

    EmailPlug.init(Keyword.merge(base, Keyword.delete(over, :brief)))
  end

  defp params(over \\ %{}, b \\ brief()) do
    Map.merge(
      %{
        "from" => @sender,
        "in_reply_to" => bare(Brief.render(b).message_id),
        "text" => "Approve 1.",
        "subject" => "Re: brief",
        "message_id" => "m-#{System.unique_integer([:positive])}",
        "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
        "reply_tokens" => %{"1" => Brief.reply_token(b, 1)}
      },
      over
    )
  end

  defp post(p, auth \\ "Bearer " <> @secret) do
    c = conn(:post, "/v1/email:ingest", p)
    if auth, do: put_req_header(c, "authorization", auth), else: c
  end

  defp dispatched(rec), do: Agent.get(rec, & &1.dispatched)

  test "missing provider webhook credential => 401, nothing dispatched", ctx do
    c = EmailPlug.call(post(params(), nil), opts(ctx.rec, ctx.ledger))
    assert c.status == 401
    assert dispatched(ctx.rec) == []
  end

  test "wrong provider webhook credential => 401 even with forged passing auth_results", ctx do
    c = EmailPlug.call(post(params(), "Bearer wrong-wrong-wrong-wrong"), opts(ctx.rec, ctx.ledger))
    assert c.status == 401
    assert dispatched(ctx.rec) == []
  end

  test "valid webhook credential => 200 dispatch (control)", ctx do
    c = EmailPlug.call(post(params()), opts(ctx.rec, ctx.ledger))
    assert c.status == 200, c.resp_body
    assert [{%{id: "principal:approver"}, 1}] = dispatched(ctx.rec)
  end

  test "no :webhook option configured => 503, fail closed", ctx do
    o = opts(ctx.rec, ctx.ledger, webhook: nil)
    c = EmailPlug.call(post(params()), o)
    assert c.status == 503
    assert dispatched(ctx.rec) == []
  end

  test "no token ledger configured => 503 replay_protection_unconfigured", ctx do
    o = opts(ctx.rec, ctx.ledger, token_ledger: nil)
    c = EmailPlug.call(post(params()), o)
    assert c.status == 503
    assert Jason.decode!(c.resp_body)["error"] == "replay_protection_unconfigured"
    assert dispatched(ctx.rec) == []
  end

  test "replayed reply with a different message_id => 409, dispatched once", ctx do
    o = opts(ctx.rec, ctx.ledger)
    assert EmailPlug.call(post(params(%{"message_id" => "m-a"})), o).status == 200
    c = EmailPlug.call(post(params(%{"message_id" => "m-b"})), o)
    assert c.status == 409
    assert length(dispatched(ctx.rec)) == 1
  end

  test "oversized raw body => 413", ctx do
    o = opts(ctx.rec, ctx.ledger, max_body_bytes: 1_000)
    big = Jason.encode!(%{"from" => @sender, "text" => String.duplicate("x", 5_000)})

    c =
      conn(:post, "/v1/email:ingest", big)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> @secret)
      |> EmailPlug.call(o)

    assert c.status == 413
    assert dispatched(ctx.rec) == []
  end

  test "oversized reply text => 413", ctx do
    o = opts(ctx.rec, ctx.ledger, max_reply_chars: 50)
    c = EmailPlug.call(post(params(%{"text" => "Approve 1. " <> String.duplicate("y", 200)})), o)
    assert c.status == 413
    assert dispatched(ctx.rec) == []
  end

  test "deeply nested body => 413", ctx do
    deep = Enum.reduce(1..20, "leaf", fn _, acc -> %{"k" => acc} end)
    c = EmailPlug.call(post(params(%{"extra" => deep})), opts(ctx.rec, ctx.ledger))
    assert c.status == 413
    assert dispatched(ctx.rec) == []
  end

  test "approver binding: brief for another principal => 403, no dispatch", ctx do
    b = brief(%{approver: "principal:someone-else"})
    c = EmailPlug.call(post(params(%{}, b)), opts(ctx.rec, ctx.ledger, brief: b))
    assert c.status == 403
    assert Jason.decode!(c.resp_body)["error"] == "approver_mismatch"
    assert dispatched(ctx.rec) == []
  end

  test "approver binding: matching principal is accepted", ctx do
    b = brief(%{approver: "principal:approver"})
    c = EmailPlug.call(post(params(%{}, b)), opts(ctx.rec, ctx.ledger, brief: b))
    assert c.status == 200, c.resp_body
  end

  test "CRLF in subject cannot inject headers into the reply", ctx do
    evil = "Re: x\r\nBcc: attacker@evil.test"
    c = EmailPlug.call(post(params(%{"subject" => evil})), opts(ctx.rec, ctx.ledger))
    assert c.status == 200, c.resp_body

    for {_to, subject, _} <- Agent.get(ctx.rec, & &1.replies) do
      refute subject =~ "\r"
      refute subject =~ "\n"
    end
  end
end
