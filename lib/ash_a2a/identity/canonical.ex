defmodule AshA2A.Identity.Canonical do
  @moduledoc false
  alias AshA2A.Identity.Canonical.{Encodable, Normalizer}

  def normalize(value), do: Normalizer.normalize(value)

  @doc "Canonical JCS (RFC 8785) bytes of `value` after validation and normalization."
  @spec encode(term()) :: {:ok, binary()} | {:error, atom()}
  def encode(value) do
    with :ok <- Encodable.validate(value),
         {:ok, normalized} <- Normalizer.normalize(value) do
      jcs(normalized)
    end
  end

  def digest(value) do
    with {:ok, bytes} <- encode(value) do
      {:ok, "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end
  end

  defp jcs(value) do
    {:ok, Jcs.encode(value)}
  rescue
    _ -> {:error, :canonical_unencodable}
  end
end
