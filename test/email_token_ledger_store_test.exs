defmodule AshA2A.EmailTokenLedgerStoreTest do
  @moduledoc """
  W2-07: `AshA2A.Email.TokenLedgerStore` on a real EKV instance, driven directly and through the
  real `AshA2A.Email.Plug` (the plug is unchanged; the store answers the ledger calls).
  Standing: UNVERIFIED (not run; no Elixir toolchain when written).
  """
  use ExUnit.Case, async: false
  @moduletag :serial

  import Plug.Test
  import Plug.Conn

  alias AshA2A.Email.{Brief, TokenLedgerStore}
  alias AshA2A.Email.Plug, as: EmailPlug

  @digest "sha256:" <> String.duplicate("a", 64)
  @sender "approver@example.test"
  @secret "0123456789abcdef-secret"

  defp uniq, do: System.unique_integer([:positive])

  setup do
    id = uniq()
    kv = :"w207_kv_#{id}"
    dir = Path.join(System.tmp_dir!(), "w207_#{id}")
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: kv, data_dir: dir))
    {:ok, rec} = Agent.start_link(fn -> [] end)
    {:ok, kv: kv, dir: dir, rec: rec}
  end

  defp start_ledger(kv, extra \\ []) do
    start_supervised!({TokenLedgerStore, [store: kv] ++ extra}, id: {:ledger, uniq()})
  end

  test "reserve consumes once; different message_id is already_consumed", %{kv: kv} do
    l = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
    assert {:error, :already_consumed} = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m2")
    assert {:error, :already_consumed} = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], nil)
  end

  test "exact replay returns the cached body", %{kv: kv} do
    l = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
    assert {:replay, nil} = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
    assert :ok = TokenLedgerStore.record_result(l, "b1", "m1", %{"results" => []})
    assert {:replay, %{"results" => []}} = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
  end

  test "multi-key reserve is all-or-nothing", %{kv: kv} do
    l = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{2, "t2"}], "m1")
    assert {:error, :already_consumed} = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}, {2, "t2"}], "m2")
    # key 1 was rolled back, so it is still spendable
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m3")
  end

  test "consumption survives a ledger and EKV restart", %{kv: kv, dir: dir} do
    l = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{1, "t1"}], "m1")
    :ok = stop_supervised({EKV, kv})
    start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: kv, data_dir: dir), id: :kv2)
    l2 = start_ledger(kv)
    assert {:error, :already_consumed} = TokenLedgerStore.reserve(l2, "b1", [{1, "t1"}], "m9")
  end

  test "two ledger processes over one store share consumption (stands in for two nodes)", %{kv: kv} do
    a = start_ledger(kv)
    b = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(a, "b1", [{1, "t1"}], "m1")
    assert {:error, :already_consumed} = TokenLedgerStore.reserve(b, "b1", [{1, "t1"}], "m2")
  end

  test "raw tokens are not written under their own value", %{kv: kv} do
    l = start_ledger(kv)
    assert :ok = TokenLedgerStore.reserve(l, "b1", [{1, "secret-token-xyz"}], "m1")
    assert EKV.get(kv, "email_ledger/key/secret-token-xyz") == nil
  end

  test "rate_check is a sliding window", %{kv: kv} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    l = start_ledger(kv, now: fn -> Agent.get(clock, & &1) end)
    assert :ok = TokenLedgerStore.rate_check(l, "s", 2, 1000)
    assert :ok = TokenLedgerStore.rate_check(l, "s", 2, 1000)
    assert {:error, :rate_limited} = TokenLedgerStore.rate_check(l, "s", 2, 1000)
    Agent.update(clock, fn _ -> 2000 end)
    assert :ok = TokenLedgerStore.rate_check(l, "s", 2, 1000)
  end

  # -- through the real plug ---------------------------------------------------

  defp bare(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")

  defp brief do
    %{
      title: "Daily",
      date: "2026-11-13",
      sections: [],
      actions: [%{n: 1, summary: "Deploy A", action: :deploy, args: %{}, graph_digest: @digest}]
    }
  end

  defp plug_opts(rec, ledger) do
    b = brief()
    mid = bare(Brief.render(b).message_id)

    EmailPlug.init(
      policy: %{allowlist: %{@sender => "principal:approver"}},
      webhook: {:workspace, token: @secret},
      token_ledger: ledger,
      brief_lookup: fn
        ^mid -> {:ok, b, %{1 => @digest}}
        _ -> :error
      end,
      dispatch: fn _principal, action ->
        Agent.update(rec, &(&1 ++ [action.n]))
        {:ok, :done}
      end
    )
  end

  defp req(mid) do
    b = brief()

    conn(:post, "/v1/email:ingest", %{
      "from" => @sender,
      "in_reply_to" => bare(Brief.render(b).message_id),
      "text" => "Approve 1.",
      "subject" => "Re: brief",
      "message_id" => mid,
      "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
      "reply_tokens" => %{"1" => Brief.reply_token(b, 1)}
    })
    |> put_req_header("authorization", "Bearer " <> @secret)
  end

  test "real plug: replay with another message_id is 409 and dispatched once; same id replays", ctx do
    l = start_ledger(ctx.kv)
    o = plug_opts(ctx.rec, l)

    assert EmailPlug.call(req("m-a"), o).status == 200
    assert EmailPlug.call(req("m-a"), o).status == 200
    c = EmailPlug.call(req("m-b"), o)
    assert c.status == 409
    assert Jason.decode!(c.resp_body)["error"] == "already_consumed"
    assert Agent.get(ctx.rec, & &1) == [1]
  end

  test "real plug: refusal persists across a restart of the ledger and store", ctx do
    l = start_ledger(ctx.kv)
    assert EmailPlug.call(req("m-a"), plug_opts(ctx.rec, l)).status == 200

    :ok = stop_supervised({EKV, ctx.kv})
    start_supervised!(AshA2A.TaskStore.Ekv.child_spec(name: ctx.kv, data_dir: ctx.dir), id: :kv2)
    l2 = start_ledger(ctx.kv)

    c = EmailPlug.call(req("m-b"), plug_opts(ctx.rec, l2))
    assert c.status == 409
    assert Agent.get(ctx.rec, & &1) == [1]
  end
end
