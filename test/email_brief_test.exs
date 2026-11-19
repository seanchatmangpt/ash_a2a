defmodule AshA2A.EmailBriefTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.Brief

  @d1 "sha256:" <> String.duplicate("1", 64)
  @d2 "sha256:" <> String.duplicate("2", 64)

  defp brief(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Daily",
        date: "2026-11-13",
        sections: [%{heading: "Status", lines: ["all <green>"]}],
        actions: [
          %{n: 2, summary: "Rotate B", action: :rotate, args: %{k: 1}, graph_digest: @d2},
          %{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @d1}
        ]
      },
      overrides
    )
  end

  test "render is byte-identical across calls and action order" do
    b = brief()
    flipped = %{b | actions: Enum.reverse(b.actions)}
    assert Brief.render(b) == Brief.render(b)
    assert Brief.render(b).message_id == Brief.render(flipped).message_id
    assert Brief.brief_digest(b) == Brief.brief_digest(flipped)
  end

  test "message id, headers, and html escaping" do
    r = Brief.render(brief(), domain: "ex.test")
    assert r.message_id =~ ~r/\A<brief\.[0-9a-f]{16}@ex\.test>\z/
    assert {"A2A-Action-1", Brief.reply_token(brief(), 1)} in r.headers
    assert r.html =~ "all &lt;green&gt;"
    assert r.text =~ "[1] Deploy A"
  end

  test "tokens verify; wrong token, other action's token, unknown action fail closed" do
    b = brief()
    t1 = Brief.reply_token(b, 1)
    assert :ok = Brief.verify_reply_token(b, 1, t1)
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, t1 <> "0")
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, Brief.reply_token(b, 2))
    assert {:error, :bad_token} = Brief.verify_reply_token(b, 1, nil)
    assert {:error, :unknown_action} = Brief.verify_reply_token(b, 9, t1)
  end

  test "content change invalidates old tokens" do
    b = brief()

    changed = %{
      b
      | actions: Enum.map(b.actions, &if(&1.n == 1, do: %{&1 | graph_digest: @d2}, else: &1))
    }

    t = Brief.reply_token(b, 1)
    refute Brief.reply_token(changed, 1) == t
    assert {:error, :bad_token} = Brief.verify_reply_token(changed, 1, t)
  end

  test "malformed graph_digest raises" do
    bad = brief(%{actions: [%{n: 1, summary: "x", action: :a, args: %{}, graph_digest: "nope"}]})
    assert_raise ArgumentError, fn -> Brief.render(bad) end
  end
end
