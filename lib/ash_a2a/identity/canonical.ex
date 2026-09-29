defmodule AshA2A.Identity.Canonical do
  @moduledoc false
  def digest(value) do
    bytes = Jcs.encode(value)
    {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  rescue
    _ -> {:error, :canonical_unencodable}
  end
end
