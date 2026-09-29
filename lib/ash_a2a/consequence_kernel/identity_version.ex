defmodule AshA2A.ConsequenceKernel.IdentityVersion do
  @moduledoc false
  @version "sa2a.c1.identity.v1"
  def current, do: @version
  def admit(@version), do: :ok
  def admit(_), do: {:error,:canonical_schema_tag_required}
end
