# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceKernel.Runtime.PreparedDigest do
  @moduledoc "Single accessor for the authenticated prepared-effect identity."
  def fetch(%{prepared_digest: digest}) when is_binary(digest) and byte_size(digest) > 0,
    do: {:ok, digest}

  def fetch(_), do: {:error, :prepared_digest_missing}
end
