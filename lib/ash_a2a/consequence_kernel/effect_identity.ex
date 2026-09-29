defmodule AshA2A.ConsequenceKernel.EffectIdentity do
 def derive(r,e), do: AshA2A.Identity.Canonical.digest(%{"kind"=>"effect","request_id"=>r,"effect"=>e})
end
