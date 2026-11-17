defmodule AshA2A.EmailSignedContentBindingTest do
  @moduledoc """
  A signature on the raw message in `"content"` (the DKIM verifier of the `:ses` webhook) vouches
  for that message only. The sender, reply text, ids and tokens the plug acts on come from the
  other envelope fields, so they must equal what the signed message says. Driven through
  `Plug.Test` with the real plug, Brief, Inbound and TokenLedger; the verifier is a hand-written
  function that accepts the message (the cryptography is covered by `email_dkim_test.exs`).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshA2A.Email.{Brief, TokenLedger}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"
  @brief %{
    title: "Daily",
    date: "2026-11-13",
    sections: [],
    actions: [%{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest}]
  }

  setup do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {:ok, ledger} = TokenLedger.start_link()

    mid =
      @brief |> Brief.render() |> Map.fetch!(:message_id) |> String.trim("<") |> String.trim(">")

    opts =
      EmailPlug.init(
        policy: %{allowlist: %{@sender => "principal:approver"}},
        webhook: {:ses, structure_only: true, signature_verifier: fn _body -> true end},
        token_ledger: ledger,
        brief_lookup: fn ^mid -> {:ok, @brief, %{1 => @digest}} end,
        dispatch: fn _principal, action ->
          Agent.update(rec, &(&1 ++ [action.n]))
          {:ok, :done}
        end
      )

    {:ok, rec: rec, opts: opts, mid: mid}
  end

  defp raw(mid, text, from \\ @sender) do
    "From: Approver <#{from}>\r\nTo: briefs@example.test\r\nSubject: Re: brief\r\n" <>
      "Message-ID: <reply-#{System.unique_integer([:positive])}@example.test>\r\n" <>
      "In-Reply-To: <#{mid}>\r\n\r\n#{text}\r\n"
  end

  defp envelope(raw, mid, over \\ %{}) do
    {:ok, signed} = AshA2A.Email.Inbound.parse(raw)

    Map.merge(
      %{
        "Type" => "Notification",
        "MessageId" => "sns-1",
        "TopicArn" => "arn:aws:sns:us-east-1:1:t",
        "Timestamp" => "2026-11-17T00:00:00Z",
        "Signature" => Base.encode64("s"),
        "SignatureVersion" => "1",
        "SigningCertURL" => "https://sns.us-east-1.amazonaws.com/c.pem",
        "content" => raw,
        "from" => signed.from,
        "message_id" => signed.message_id,
        "in_reply_to" => mid,
        "text" => AshA2A.Email.Inbound.reply_text(signed),
        "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
        "reply_tokens" => %{"1" => Brief.reply_token(@brief, 1)}
      },
      over
    )
  end

  test "envelope fields that match the signed message are accepted (control)", ctx do
    raw = raw(ctx.mid, "Approve 1.")
    c = EmailPlug.call(conn(:post, "/v1/email:ingest", envelope(raw, ctx.mid)), ctx.opts)
    assert c.status == 200, c.resp_body
    assert Agent.get(ctx.rec, & &1) == [1]
  end

  test "reply text that differs from the signed message is refused, nothing dispatched", ctx do
    raw = raw(ctx.mid, "Hold 1.")

    c =
      EmailPlug.call(
        conn(:post, "/v1/email:ingest", envelope(raw, ctx.mid, %{"text" => "Approve 1."})),
        ctx.opts
      )

    assert c.status == 401
    assert Jason.decode!(c.resp_body)["error"] == "webhook_unauthorized"
    assert Agent.get(ctx.rec, & &1) == []
  end

  test "a sender the signed message does not name is refused, nothing dispatched", ctx do
    raw = raw(ctx.mid, "Approve 1.", "someone@example.test")

    c =
      EmailPlug.call(
        conn(:post, "/v1/email:ingest", envelope(raw, ctx.mid, %{"from" => @sender})),
        ctx.opts
      )

    assert c.status == 401
    assert Agent.get(ctx.rec, & &1) == []
  end

  test "a different in-reply-to than the signed message is refused", ctx do
    raw = raw(ctx.mid, "Approve 1.")

    c =
      EmailPlug.call(
        conn(:post, "/v1/email:ingest", envelope(raw, ctx.mid, %{"message_id" => "other-id"})),
        ctx.opts
      )

    assert c.status == 401
    assert Agent.get(ctx.rec, & &1) == []
  end
end
