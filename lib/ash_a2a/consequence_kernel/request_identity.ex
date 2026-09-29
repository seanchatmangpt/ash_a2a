defmodule AshA2A.ConsequenceKernel.RequestIdentity do
  @moduledoc false
  def derive(request),
    do: AshA2A.Identity.Canonical.Migration.tagged_digest("sa2a.request.v1", request)
end
