defmodule AshA2A.Gall.Closure.ProducerPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Gall.Closure.ProducerPolicy

  test "pins repository and SHA jointly" do
    sha = String.duplicate("a", 40)
    candidate = %{producer_repository: "seanchatmangpt/beam4pm", producer_sha: sha}
    assert {:ok, ^candidate} = ProducerPolicy.admit(candidate, %{"seanchatmangpt/beam4pm" => sha})

    assert {:error, {:refused_gall, :producer_policy, {:sha_mismatch, _, _}}} =
             ProducerPolicy.admit(candidate, %{
               "seanchatmangpt/beam4pm" => String.duplicate("b", 40)
             })
  end
end
