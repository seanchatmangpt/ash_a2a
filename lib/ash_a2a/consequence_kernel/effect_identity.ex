defmodule AshA2A.ConsequenceKernel.EffectIdentity do
  @moduledoc false
  def derive(request_id,effect), do: AshA2A.Identity.Canonical.Migration.tagged_digest("sa2a.effect.v1",%{"request_id"=>request_id,"effect"=>effect})
end
