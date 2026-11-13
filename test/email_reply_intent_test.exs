defmodule AshA2A.EmailReplyIntentTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.ReplyIntent

  defp decisions(text, nums \\ [1, 2, 3]) do
    {:ok, entries} = ReplyIntent.parse(text, nums)
    Map.new(entries, &{&1.n, &1.decision})
  end

  test "mixed approve and hold with note" do
    {:ok, entries} =
      ReplyIntent.parse("Approve 1 and 3. Hold 2 until I talk to Larson.", [1, 2, 3])

    assert Map.new(entries, &{&1.n, &1.decision}) == %{1 => :approve, 2 => :hold, 3 => :approve}
    assert Enum.find(entries, &(&1.n == 2)).note =~ "until I talk to Larson"
  end

  test "all approves every action" do
    assert {:error, :no_decisions} = ReplyIntent.parse("all", [1, 2, 3])
    assert decisions("Approve all") == %{1 => :approve, 2 => :approve, 3 => :approve}
  end

  test "out-of-range number is ambiguous" do
    assert {:error, :ambiguous} = ReplyIntent.parse("Approve 7", [1, 2, 3])
  end

  test "conflicting decisions for one action are ambiguous" do
    assert {:error, :ambiguous} = ReplyIntent.parse("Approve 1. Reject 1.", [1, 2, 3])
  end

  test "unmentioned actions are :unknown and never resolved as approved" do
    {:ok, entries} = ReplyIntent.parse("Approve 1", [1, 2, 3])

    assert Map.new(entries, &{&1.n, &1.decision}) == %{
             1 => :approve,
             2 => :unknown,
             3 => :unknown
           }

    actions = [%{n: 1}, %{n: 2}, %{n: 3}]
    assert ReplyIntent.resolve(entries, actions) == [%{n: 1}]
  end

  test "no recognisable decision => :no_decisions" do
    assert {:error, :no_decisions} = ReplyIntent.parse("thanks, talk soon", [1, 2, 3])
  end
end
