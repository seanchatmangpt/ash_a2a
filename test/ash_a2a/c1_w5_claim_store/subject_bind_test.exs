defmodule AshA2A.C1W5ClaimStore.SubjectBindTest do
  use ExUnit.Case, async: true

  test "subject_bind" do
    vector =
      Path.join([
        File.cwd!(),
        "priv",
        "sa2a",
        "c1",
        "w5_claim_store_vectors",
        "subject_bind.json"
      ])

    assert File.read!(vector) =~ "\"case\": \"subject_bind\""
    p = %{prepared_digest: "sha256:prep", instance: %{subject_digest: "sha256:sub"}}
    c = %{prepared_digest: "sha256:prep", subject_digest: "sha256:sub"}
    assert :ok = AshA2A.ConsequenceKernel.W5.ClaimSubject.bind(p, c)
  end
end
