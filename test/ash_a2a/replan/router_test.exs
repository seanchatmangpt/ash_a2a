defmodule AshA2A.Replan.RouterTest do
  use ExUnit.Case, async: true

  test "failed becomes replan" do
    assert %{kind: :replan} = AshA2A.Replan.Router.decide(%{subject: "s", outcome: :failed})
  end
end
