# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SPIFFE.AttestedIdentity do
  @moduledoc """
  A `AshA2A.SPIFFE.Identity` attested with an SVID type, bundle digest, and observation
  time by `from_verified/2`. Evidence of who spoke, absorbed below SA2A authority; it
  grants no authority.
  """

  alias AshA2A.SPIFFE.Identity
  @enforce_keys [:identity, :svid_type, :bundle_digest, :observed_at]
  defstruct @enforce_keys

  def from_verified(raw_spiffe_id, opts) when is_list(opts) do
    with {:ok, identity} <- Identity.parse(raw_spiffe_id),
         svid_type when svid_type in [:x509, :jwt] <- Keyword.get(opts, :svid_type),
         bundle_digest when is_binary(bundle_digest) and byte_size(bundle_digest) > 0 <-
           Keyword.get(opts, :bundle_digest),
         observed_at when is_integer(observed_at) <- Keyword.get(opts, :observed_at) do
      {:ok,
       %__MODULE__{
         identity: identity,
         svid_type: svid_type,
         bundle_digest: bundle_digest,
         observed_at: observed_at
       }}
    else
      _ -> {:error, :invalid_attested_identity}
    end
  end
end
