defmodule AshA2A.C1W5ClaimStore.TransitionDoingTest do
  use ExUnit.Case, async: true

  test "transition_doing" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "transition_doing.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"transition_doing\""
    assert :ok = AshA2A.ConsequenceKernel.W5.ClaimTransition.admit(:claimed, :doing)
  end
end
