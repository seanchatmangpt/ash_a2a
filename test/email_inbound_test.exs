defmodule AshA2A.EmailInboundTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.Inbound

  @policy %{allowlist: %{"vito@example.com" => "principal:vito"}}

  defp inbound(auth, from \\ "Vito <vito@example.com>") do
    {:ok, i} =
      Inbound.parse(%{
        "from" => from,
        "text" => "Approve 1",
        "in_reply_to" => "<brief.abc@a2a.local>",
        "auth_results" => auth
      })

    i
  end

  @pass %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"}

  test "all pass + allowlisted => identity-only principal" do
    assert {:ok, p} = Inbound.verify_sender(inbound(@pass), @policy)

    assert p == %{
             id: "principal:vito",
             address: "vito@example.com",
             authenticated_via: :email,
             authority: :none
           }
  end

  test "in_reply_to angle brackets stripped" do
    assert inbound(@pass).in_reply_to == "brief.abc@a2a.local"
  end

  for k <- ["dkim", "spf", "dmarc"] do
    test "#{k} fail closes" do
      auth = Map.put(@pass, unquote(k), "fail")
      assert {:error, reason} = Inbound.verify_sender(inbound(auth), @policy)
      assert reason == String.to_atom(unquote(k) <> "_fail")
    end

    test "#{k} missing closes" do
      auth = Map.delete(@pass, unquote(k))
      assert {:error, _} = Inbound.verify_sender(inbound(auth), @policy)
    end
  end

  test "unsigned (no verdicts) => :unsigned" do
    assert {:error, :unsigned} = Inbound.verify_sender(inbound(%{}), @policy)
  end

  test "not on allowlist => :sender_not_allowlisted" do
    assert {:error, :sender_not_allowlisted} =
             Inbound.verify_sender(inbound(@pass, "evil@example.com"), @policy)
  end

  test "raw RFC 5322 Authentication-Results header is parsed" do
    raw =
      "From: Vito <vito@example.com>\nTo: a@b.c\nSubject: Re: x\nMessage-ID: <m1@x>\n" <>
        "In-Reply-To: <brief.abc@a2a.local>\n" <>
        "Authentication-Results: mx; dkim=pass; spf=pass; dmarc=fail\n\nApprove 1\n"

    assert {:ok, i} = Inbound.parse(raw)
    assert i.auth_results == %{dkim: :pass, spf: :pass, dmarc: :fail}
    assert {:error, :dmarc_fail} = Inbound.verify_sender(i, @policy)
  end

  test "quote stripping removes quoted lines, attribution tail and signature" do
    body = """
    Approve 1 and 3.

    On Mon, Nov 9, 2026 at 8:00 AM A2A <brief@a2a.local> wrote:
    > [1] Deploy A
    > Reply with the number to approve.
    """

    assert Inbound.reply_text(body) == "Approve 1 and 3."
    assert Inbound.reply_text("Hold 2\n> quoted\n-- \nVito") == "Hold 2"
  end

  test "missing from => error" do
    assert {:error, :missing_from} = Inbound.parse(%{"text" => "x"})
  end
end
