defmodule AshA2A.ConsequenceKernel.Runtime.PreparedDigest do
  @moduledoc "Single accessor for the authenticated prepared-effect identity."
  def fetch(%{prepared_digest: digest}) when is_binary(digest) and byte_size(digest) > 0,
    do: {:ok, digest}

  def fetch(_), do: {:error, :prepared_digest_missing}
end
