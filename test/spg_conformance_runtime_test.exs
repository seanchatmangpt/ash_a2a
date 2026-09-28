defmodule AshA2A.SpgConformanceRuntimeTest do
  use ExUnit.Case, async: true

  alias AshA2A.SpgConformance

  setup_all do
    cases = SpgConformance.load_all()
    {:ok, cases: cases}
  end

  test "the executable corpus is complete, balanced, unique, and seeded", %{cases: cases} do
    assert length(cases) == 56
    assert Enum.count(cases, &(&1["expect"] == "admit")) == 28
    assert Enum.count(cases, &(&1["expect"] == "refuse")) == 28
    assert Enum.map(cases, & &1["case_id"]) ==
             Enum.map(1..56, &"SPG-#{String.pad_leading(Integer.to_string(&1), 3, "0")}")

    assert Enum.map(cases, &get_in(&1, ["replay", "seed"])) == Enum.to_list(1..56)
    assert Enum.all?(cases, fn case -> match?({:ok, _}, SpgConformance.validate_case(case)) end)
  end

  test "reference runtime executes all 56 fixtures from stimulus, not oracle", %{cases: cases} do
    assert {:ok, summary} = SpgConformance.run_cases(cases)
    assert summary.total == 56
    assert summary.admitted == 28
    assert summary.refused == 28
    assert String.starts_with?(summary.corpus_digest, "sha256:")
  end

  test "corpus and case digests are deterministic and stimulus-bearing", %{cases: cases} do
    assert SpgConformance.corpus_digest(cases) == SpgConformance.corpus_digest(cases)

    first = hd(cases)
    mutated = put_in(first, ["stimulus", "checks", Access.at(0), "predicate"], "identity.changed")

    refute SpgConformance.case_digest(first) == SpgConformance.case_digest(mutated)
  end

  test "oracle cannot be flipped without independently changing the stimulus", %{cases: cases} do
    first = hd(cases)
    forged = Map.put(first, "expect", "refuse")

    assert {:error, {:invalid_spg_case, "SPG-001", _}} =
             SpgConformance.evaluate(forged)
  end

  test "typed refusal code laundering is detected", %{cases: cases} do
    refused = Enum.find(cases, &(&1["case_id"] == "SPG-002"))

    evaluator = fn _case ->
      {:refuse, "SPG_IDENTITY_WRONG_REFUSAL"}
    end

    assert {:error,
            {:refusal_code_drift, "SPG_IDENTITY_SUBJECT_SHA_MISMATCH",
             "SPG_IDENTITY_WRONG_REFUSAL"}} =
             SpgConformance.evaluate(refused, evaluator)
  end

  test "false admission of a negative case is rejected", %{cases: cases} do
    refused = Enum.find(cases, &(&1["case_id"] == "SPG-007"))

    evaluator = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "authority" => %{"explicit" => true},
         "receipt" => %{"case_id" => case["case_id"]}
       }}
    end

    assert {:error, :false_admission} = SpgConformance.evaluate(refused, evaluator)
  end

  test "admitted consumer must preserve exact subject identity", %{cases: cases} do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-004"))

    evaluator = fn case ->
      projection =
        case
        |> SpgConformance.reference_evaluator()
        |> elem(1)
        |> put_in(["subject", "base_sha"], String.duplicate("f", 40))

      {:admit, projection}
    end

    assert {:error, :subject_identity_drift} = SpgConformance.evaluate(admitted, evaluator)
  end

  test "admitted consumer must preserve procedure authority and receipt projections", %{
    cases: cases
  } do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-044"))

    missing_authority = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "receipt" => %{}
       }}
    end

    assert {:error, :authority_projection_missing} =
             SpgConformance.evaluate(admitted, missing_authority)

    missing_receipt = fn case ->
      {:admit,
       %{
         "subject" => case["subject"],
         "procedure" => case["procedure"],
         "authority" => %{}
       }}
    end

    assert {:error, :receipt_projection_missing} =
             SpgConformance.evaluate(admitted, missing_receipt)
  end

  test "two-pass replay detects evaluator nondeterminism", %{cases: cases} do
    admitted = Enum.find(cases, &(&1["case_id"] == "SPG-026"))
    key = make_ref()
    Process.put(key, 0)

    evaluator = fn case ->
      count = Process.get(key, 0)
      Process.put(key, count + 1)

      if rem(count, 2) == 0 do
        SpgConformance.reference_evaluator(case)
      else
        {:refuse, "SPG_REPLAY_NONDETERMINISTIC"}
      end
    end

    assert {:error, :nondeterministic_replay} =
             SpgConformance.evaluate(admitted, evaluator)
  end

  test "duplicate semantic case identity is refused before execution", %{cases: cases} do
    duplicate = cases ++ [hd(cases)]
    assert {:error, :duplicate_case_id} = SpgConformance.run_cases(duplicate)
  end
end
