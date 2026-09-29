defmodule AshA2A.Replan.RefusalTaxonomyTest do
  use ExUnit.Case, async: true

  test "taxonomy contains subject drift and exhaustion" do
    codes = AshA2A.Replan.Refusal.codes()
    assert :replan_subject_drift in codes
    assert :replan_exhausted in codes
  end
end
