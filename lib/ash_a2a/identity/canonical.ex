defmodule AshA2A.Identity.Canonical do
  @moduledoc false
  alias AshA2A.Identity.Canonical.{Encodable,Normalizer}
  def normalize(value), do: Normalizer.normalize(value)
  def digest(value) do
    with :ok <- Encodable.validate(value),
         {:ok, normalized} <- Normalizer.normalize(value),
         {:ok, bytes} <- encode(normalized) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  end
  defp encode(value) do
    try do {:ok, Jcs.encode(value)} rescue _ -> {:error,:canonical_unencodable} end
  end
end
