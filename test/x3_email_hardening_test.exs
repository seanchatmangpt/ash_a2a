defmodule AshA2A.X3EmailHardeningTest do
  @moduledoc """
  Real Plug + real Brief/Inbound/ReplyIntent + real TokenLedger process.

  Named exception: dispatch/reply_sender are hand-written function fakes recording into an
  Agent (governed agent and SMTP are infeasible in-process).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshA2A.Email.{Brief, TokenLedger}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @stale "sha256:" <> String.duplicate("b", 64)
  @sender "approver@example.test"

  setup do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {:ok, ledger} = TokenLedger.start_link([])
    {:ok, rec: rec, ledger: ledger}
  end

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [
        %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest},
        %{n: 2, summary: "Rotate B", action: :rotate, args: %{}, graph_digest: @digest}
      ]
    }
  end

  defp bare(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp opts(rec, ledger, over \\ []) do
    b = brief()
    mid = bare(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest, 2 => @digest}}
        _ -> :error
      end,
      dispatch: fn principal, action ->
        Agent.update(rec, &(&1 ++ [{principal, action.n}]))
        {:ok, :done}
      end,
      token_ledger: ledger
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp req(text, message_id \\ nil) do
    b = brief()

    params = %{
      "from" => @sender,
      "in_reply_to" => bare(Brief.render(b).message_id),
      "text" => text,
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => Map.new([1, 2], &{Integer.to_string(&1), Brief.reply_token(b, &1)})
    }

    params = if message_id, do: Map.put(params, "message_id", message_id), else: params
    conn(:post, "/v1/email:ingest", params)
  end

  defp dispatched(rec), do: Agent.get(rec, & &1)

  test "nil current digest is refused 409, no dispatch", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)
    o = opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, b} end)

    conn = EmailPlug.call(req("Approve 1."), o)
    assert conn.status == 409
    assert dispatched(rec) == []
  end

  test "nil digest on the brief action side is refused 409", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)
    nil_b = update_in(b.actions, fn [a1, a2] -> [Map.put(a1, :graph_digest, nil), a2] end)

    o =
      opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, nil_b, %{1 => @digest, 2 => @digest}} end)

    # Tokens in the request are bound to the original brief; a mismatching token halts at 403
    # before freshness, so mint the request against nil_b's tokens.
    params = %{
      "from" => @sender,
      "in_reply_to" => mid,
      "text" => "Approve 1.",
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => %{"1" => reply_token_nilsafe(nil_b)}
    }

    conn = EmailPlug.call(conn(:post, "/v1/email:ingest", params), o)
    assert conn.status == 409
    assert dispatched(rec) == []
  end

  # Brief.reply_token works on canonical encoding which tolerates nil digests (render does not).
  defp reply_token_nilsafe(b), do: Brief.reply_token(b, 1)

  test "stale digest is 409 and does not consume the token", %{rec: rec, ledger: ledger} do
    b = brief()
    mid = bare(Brief.render(b).message_id)

    stale_o =
      opts(rec, ledger, brief_lookup: fn ^mid -> {:ok, b, %{1 => @stale, 2 => @digest}} end)

    assert EmailPlug.call(req("Approve 1."), stale_o).status == 409
    assert dispatched(rec) == []

    # Fresh retry of the same tokens still works: staleness never burned them.
    assert EmailPlug.call(req("Approve 1."), opts(rec, ledger)).status == 200
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1]
  end

  test "replay of a consumed token is refused 409 already_consumed", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    assert EmailPlug.call(req("Approve 1.", "m-1"), o).status == 200
    conn = EmailPlug.call(req("Approve 1.", "m-2"), o)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body)["error"] == "already_consumed"
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1]
  end

  test "replay without message-id is refused", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)
    assert EmailPlug.call(req("Approve 1."), o).status == 200
    assert EmailPlug.call(req("Approve 1."), o).status == 409
    assert length(dispatched(rec)) == 1
  end

  test "identical message-id replays cached receipt without re-dispatch",
       %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    first = EmailPlug.call(req("Approve 1.", "m-1"), o)
    again = EmailPlug.call(req("Approve 1.", "m-1"), o)

    assert first.status == 200
    assert again.status == 200
    body = Jason.decode!(again.resp_body)
    assert body["replayed"] == true
    assert body["results"] == Jason.decode!(first.resp_body)["results"]
    assert length(dispatched(rec)) == 1
  end

  test "distinct action numbers are each accepted once", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger)

    assert EmailPlug.call(req("Approve 1.", "m-1"), o).status == 200
    assert EmailPlug.call(req("Approve 2.", "m-2"), o).status == 200
    assert Enum.map(dispatched(rec), &elem(&1, 1)) == [1, 2]
    assert EmailPlug.call(req("Approve 2.", "m-3"), o).status == 409
  end

  test "per-sender rate limit returns 429 past the bound", %{rec: rec, ledger: ledger} do
    o = opts(rec, ledger, rate_limit: {2, 60_000})

    assert EmailPlug.call(req("Hold 1.", "m-1"), o).status == 200
    assert EmailPlug.call(req("Hold 1.", "m-2"), o).status == 200
    conn = EmailPlug.call(req("Hold 1.", "m-3"), o)

    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "rate_limited"
  end

  test "ledger rate window slides with an injected clock" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, l} = TokenLedger.start_link(now: fn -> Agent.get(clock, & &1) end)

    assert TokenLedger.rate_check(l, "s", 1, 100) == :ok
    assert TokenLedger.rate_check(l, "s", 1, 100) == {:error, :rate_limited}
    Agent.update(clock, fn _ -> 150 end)
    assert TokenLedger.rate_check(l, "s", 1, 100) == :ok
  end

  test "unapproved reply (bad token) is 403 and dispatch authority is untouched",
       %{rec: rec, ledger: ledger} do
    conn = req("Approve 1.")
    params = Map.put(conn.body_params, "reply_tokens", %{"1" => "0000000000000000"})
    conn = EmailPlug.call(conn(:post, "/v1/email:ingest", params), opts(rec, ledger))

    assert conn.status == 403
    assert dispatched(rec) == []
  end
end
