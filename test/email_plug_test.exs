defmodule AshA2A.EmailPlugTest do
  @moduledoc """
  Plug.Test over AshA2A.Email.Plug with real Brief, Inbound, ReplyIntent.

  Named exception: dispatch and reply_sender are hand-written real function fakes
  recording into an Agent (external SMTP and the governed agent are infeasible in-process).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshA2A.Email.Brief
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"

  setup do
    {:ok, rec} = Agent.start_link(fn -> %{dispatched: [], replies: []} end)
    on_exit(fn -> if Process.alive?(rec), do: Agent.stop(rec) end)
    {:ok, rec: rec}
  end

  # ---- adapter section -------------------------------------------------------

  defp opts(rec, over \\ []) do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest, 2 => @digest, 3 => @digest}}
        _ -> :error
      end,
      dispatch: fn principal, action ->
        Agent.update(rec, &Map.update!(&1, :dispatched, fn l -> l ++ [{principal, action}] end))
        {:ok, :done}
      end,
      reply_sender: fn to, subject, text ->
        Agent.update(rec, &Map.update!(&1, :replies, fn l -> l ++ [{to, subject, text}] end))
        :ok
      end
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [
        %{n: 1, summary: "Deploy A", action: :deploy, args: %{svc: "a"}, graph_digest: @digest},
        %{n: 2, summary: "Rotate B", action: :rotate, args: %{}, graph_digest: @digest},
        %{n: 3, summary: "Scale C", action: :scale, args: %{}, graph_digest: @digest}
      ]
    }
  end

  defp inbound_conn(b, text, dkim) do
    mid = bare_id(Brief.render(b).message_id)

    params = %{
      "from" => @sender,
      "in_reply_to" => mid,
      "text" => text,
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => dkim, "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" =>
        Map.new([1, 2, 3], fn n -> {Integer.to_string(n), Brief.reply_token(b, n)} end)
    }

    conn(:post, "/v1/email:ingest", params)
  end

  defp bare_id(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp tamper(token) when is_binary(token) do
    last = String.last(token)
    String.slice(token, 0..-2//1) <> if(last == "0", do: "1", else: "0")
  end

  # ---- helpers ---------------------------------------------------------------

  defp state(rec), do: Agent.get(rec, & &1)
  defp run(conn, opts), do: EmailPlug.call(conn, opts)

  # ---- cases -----------------------------------------------------------------

  test "bad DKIM => 401 and no dispatch", %{rec: rec} do
    conn = run(inbound_conn(brief(), "Approve 1 and 3. Hold 2.", "fail"), opts(rec))

    assert conn.status == 401
    assert state(rec).dispatched == []
  end

  test "approve 1 and 3, hold 2 => exactly two dispatched under sender principal", %{rec: rec} do
    conn =
      run(
        inbound_conn(brief(), "Approve 1 and 3. Hold 2 until I talk to Larson.", "pass"),
        opts(rec)
      )

    assert conn.status == 200, conn.resp_body
    dispatched = state(rec).dispatched
    assert Enum.map(dispatched, fn {_, a} -> a.n end) == [1, 3]

    assert Enum.all?(dispatched, fn {p, _} ->
             p.id == "principal:approver" and p.authority == :none
           end)

    standings =
      Jason.decode!(conn.resp_body)["results"] |> Map.new(&{&1["action"], &1["standing"]})

    assert standings == %{1 => "dispatched", 2 => "held", 3 => "dispatched"}
    assert [{@sender, _, _}] = state(rec).replies
  end

  test "stale graph digest => 409 and reconfirm email, no dispatch", %{rec: rec} do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)
    stale = "sha256:" <> String.duplicate("b", 64)

    o =
      opts(rec,
        brief_lookup: fn ^mid -> {:ok, b, %{1 => stale, 2 => @digest, 3 => @digest}} end
      )

    conn = run(inbound_conn(b, "Approve 1 and 3. Hold 2.", "pass"), o)

    assert conn.status == 409
    st = state(rec)
    assert st.dispatched == []
    assert length(st.replies) == 1
  end

  test "unknown in_reply_to => 404, no dispatch", %{rec: rec} do
    c = inbound_conn(brief(), "Approve 1", "pass")
    params = Map.put(c.body_params, "in_reply_to", "no-such-brief@test")
    conn = run(conn(:post, "/v1/email:ingest", params), opts(rec))

    assert conn.status == 404
    assert state(rec).dispatched == []
  end

  test "tampered token => 403, no dispatch", %{rec: rec} do
    c = inbound_conn(brief(), "Approve 1 and 3.", "pass")
    params = update_in(c.body_params, ["reply_tokens", "1"], &tamper/1)
    conn = run(conn(:post, "/v1/email:ingest", params), opts(rec))

    assert conn.status == 403
    assert state(rec).dispatched == []
  end

  test "default dispatch refuses unresolvable actions", %{rec: rec} do
    o = opts(rec, dispatch: nil)
    conn = run(inbound_conn(brief(), "Approve 1.", "pass"), o)

    assert conn.status == 200, conn.resp_body
    [r] = Jason.decode!(conn.resp_body)["results"]
    assert r["standing"] == "refused"
    assert r["reason"] =~ "unresolvable"
  end
end
