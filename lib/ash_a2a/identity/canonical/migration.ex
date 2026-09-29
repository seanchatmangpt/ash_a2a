defmodule AshA2A.Identity.Canonical.Migration do
  @moduledoc false
  alias AshA2A.Identity.Canonical

  def tagged_digest(tag, value) when is_binary(tag),
    do: Canonical.digest(%{"kind" => tag, "value" => value})

  def tagged_digest(_, _), do: {:error, :canonical_schema_tag_required}

  def verify(tag, value, expected) do
    with {:ok, ^expected} <- tagged_digest(tag, value) do
      :ok
    else
      {:ok, _} -> {:error, :canonical_digest_mismatch}
      e -> e
    end
  end
end
