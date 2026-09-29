defmodule AshA2A.ConsequenceKernel.RequestIdentity do
 def derive(x), do: AshA2A.Identity.Canonical.digest(%{"kind"=>"request","request"=>x})
end
