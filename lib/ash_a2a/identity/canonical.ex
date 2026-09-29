defmodule AshA2A.Identity.Canonical do
  @moduledoc false
  def digest(value) do
    with {:ok, bytes} <- JCS.encode(value) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    else
      _ -> {:error, :canonical_unencodable}
    end
  end
end
