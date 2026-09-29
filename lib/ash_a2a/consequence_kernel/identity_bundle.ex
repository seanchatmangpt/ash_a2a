defmodule AshA2A.ConsequenceKernel.IdentityBundle do
  @moduledoc false
  alias AshA2A.ConsequenceKernel.{EffectIdentity, ExactSubject, RequestIdentity}

  def build(request, effect, subject) do
    with {:ok, r} <- RequestIdentity.derive(request),
         {:ok, e} <- EffectIdentity.derive(r, effect),
         {:ok, s} <- ExactSubject.bind(subject) do
      {:ok, %{request_id: r, effect_id: e, subject_digest: s}}
    end
  end
end
