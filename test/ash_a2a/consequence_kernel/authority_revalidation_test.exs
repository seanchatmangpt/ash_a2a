defmodule AshA2A.AuthorityRevalidationTest do
  use ExUnit.Case, async: true

  defmodule Broker do
    def revalidate(p, s, c, e), do: {:ok, {p, s, c, e}}
  end

  test "uses live broker" do
    p = %{instance: %{subject_digest: "s"}, consequence_class: :change, authority_epoch: 2}

    assert {:ok, {"p", "s", :change, 2}} =
             AshA2A.ConsequenceKernel.AuthorityRevalidation.check(Broker, p, "p")
  end
end
