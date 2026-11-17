# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SecurityWave3EmailTest do
  @moduledoc """
  Security wave 3, email approval plug: error bodies and reply mail carry a
  closed reason code (no exception text, no receipt term), a throw or exit
  from dispatch is a refusal rather than a 500, a missing `:brief_lookup` is
  the documented 503, and a declared oversize body is refused 413 even when
  it arrives pre-parsed.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshA2A.Email.Brief
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"
  @secret "db-password-hunter2 at /srv/internal/path"

  setup do
    {:ok, rec} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(rec), do: Agent.stop(rec) end)
    {:ok, rec: rec}
  end

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [
        %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest}
      ]
    }
  end

  defp bare_id(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp opts(rec, over) do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)

    base = [
      policy: %{allowlist: %{@sender => "principal:approver"}},
      webhook: :trusted_ingress,
      unsafe_no_replay_ledger: true,
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest}}
        _ -> :error
      end,
      reply_sender: fn _to, _subject, text -> Agent.update(rec, &[text | &1]) end
    ]

    EmailPlug.init(Keyword.merge(base, over))
  end

  defp inbound do
    b = brief()
    mid = bare_id(Brief.render(b).message_id)

    conn(:post, "/v1/email:ingest", %{
      "from" => @sender,
      "in_reply_to" => mid,
      "text" => "Approve 1.",
      "subject" => "Re: brief",
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => %{"1" => Brief.reply_token(b, 1)}
    })
  end

  for {name, dispatch} <- [
        raise: quote(do: fn _p, _a -> raise unquote(@secret) end),
        error_tuple: quote(do: fn _p, _a -> {:error, {:boom, unquote(@secret)}} end),
        error_string: quote(do: fn _p, _a -> {:error, unquote(@secret)} end),
        throw: quote(do: fn _p, _a -> throw(unquote(@secret)) end),
        exit: quote(do: fn _p, _a -> exit(unquote(@secret)) end),
        receipt: quote(do: fn _p, _a -> {:ok, %{internal: unquote(@secret)}} end)
      ] do
    test "dispatch #{name}: 200 with a closed code and no internal text", %{rec: rec} do
      dispatch = unquote(dispatch)
      conn = EmailPlug.call(inbound(), opts(rec, dispatch: dispatch))

      assert conn.status == 200, conn.resp_body
      refute conn.resp_body =~ "hunter2"
      refute conn.resp_body =~ "/srv/internal"
      refute Enum.any?(Agent.get(rec, & &1), &(&1 =~ "hunter2"))
    end
  end

  test "a missing :brief_lookup is the documented 503, not a 500", %{rec: rec} do
    o = opts(rec, dispatch: fn _, _ -> {:ok, :done} end)
    o = Keyword.delete(o, :brief_lookup)
    conn = EmailPlug.call(inbound(), o)

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"] == "brief_lookup_unconfigured"
  end

  test "a pre-parsed body with an oversize content-length is refused 413", %{rec: rec} do
    o = opts(rec, dispatch: fn _, _ -> {:ok, :done} end, max_body_bytes: 1_000)
    conn = inbound() |> put_req_header("content-length", "5000000") |> then(&EmailPlug.call(&1, o))

    assert conn.status == 413
  end
end
