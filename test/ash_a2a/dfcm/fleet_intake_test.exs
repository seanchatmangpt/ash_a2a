defmodule AshA2A.DfCM.FleetIntakeTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "canonical fleet manifest is structurally admitted" do
    assert :ok = FleetIntake.validate()
    assert length(FleetIntake.ids()) == 14
  end

  test "every donor stays powerless at the SA2A boundary" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert donor["authority"] == "NONE"
      assert donor["consequence"] == "EVIDENCE_ONLY"
      assert donor["subject"] == donor["repository"] <> "@" <> donor["sha"]
      assert donor["reuse"] != []
      assert donor["negative_knowledge"] != []

      assert {:ok, envelope} = FleetIntake.envelope(id)
      assert envelope.standing == :candidate
      assert envelope.authority_requirement == "none"
      assert envelope.consequence_class == "none"
      assert envelope.subjects == [donor["subject"]]
    end
  end

  test "projections bind exact donor identity and refuse authority smuggling" do
    for id <- FleetIntake.ids() do
      assert {:ok, projection} = FleetIntake.project(id, %{"case" => "positive"})
      assert {:ok, ^projection} = FleetIntake.admit_projection(id, projection)

      assert {:error, %{code: :refused_dfcm_projection, field: :authority}} =
               FleetIntake.admit_projection(id, %{projection | "authority" => "DO"})

      assert {:error, %{code: :refused_dfcm_projection, field: :subject}} =
               FleetIntake.admit_projection(id, %{projection | "subject" => "repo@wrong"})
    end
  end
end
