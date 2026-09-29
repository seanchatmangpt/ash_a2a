defmodule AshA2A.ConsequenceKernel.AuthorityRevalidation do
  def check(authority, prepared, principal) do
    authority.revalidate(principal, prepared.instance.subject_digest, prepared.consequence_class,
      prepared.authority_epoch)
  end
end
