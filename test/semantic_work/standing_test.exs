defmodule AshA2A.SemanticWork.StandingTest do
  use ExUnit.Case, async: true
  alias AshA2A.SemanticWork.Standing

  test "requires subject-bound input" do
    assert {:error, _} = Standing.bind(%{})
    assert {:error, :refused_invalid_envelope} = Standing.bind(nil)
  end

  test "missing standing is UNKNOWN evidence-only" do
    assert {:ok, %{standing: "UNKNOWN", subject: "s", evidence: []}} =
             Standing.bind(%{subject: "s"})
  end

  test "accepts allowed standings case-insensitively" do
    for v <- ~w(UNKNOWN OBSERVED CANDIDATE ADMITTED) do
      assert {:ok, %{standing: ^v}} = Standing.bind(%{subject: "s", standing: v})
    end

    assert {:ok, %{standing: "ADMITTED"}} =
             Standing.bind(%{"subject" => "s", "standing" => "admitted"})
  end

  test "refuses authority-like or invalid standing" do
    for v <- ["AUTHORIZED", "DO", "", :admitted, 1] do
      assert {:error, {:refused_invalid_standing, ^v}} =
               Standing.bind(%{subject: "s", standing: v})
    end
  end
end
