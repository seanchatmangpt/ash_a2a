defmodule AshA2A.Replan.EffectIdentity do
  def preserve?(a,b) do
    Map.get(a,:actuation_id) == Map.get(b,:actuation_id) and AshA2A.Replan.SubjectLineage.same?(a,b)
  end
end