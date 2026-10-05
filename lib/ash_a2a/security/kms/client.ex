# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.KMS.Client do
  @moduledoc """
  Behaviour for the Key Management Service edge used by CMEK envelope
  encryption (PRD FR-03 / ARD §3.3).

  A client binds one KEK (Key Encryption Key) identified by `kek_id` and
  exposes the three operations envelope encryption needs:

    * `wrap/2` — wrap a DEK (Data Encryption Key) under the KEK's
      *current* version. Returns the wrapped DEK plus the concrete
      `kek_version_id` that did the wrapping, which is persisted beside
      the ciphertext (ARD §3.3 step 4).
    * `unwrap/3` — recover the DEK from a wrapped DEK under the exact
      version recorded in the envelope.
    * `current_version/1` — the KEK version `wrap/2` currently uses, so
      hosts and courts can pin and assert version movement on rotation.

  Production bindings shape to Google Cloud KMS, AWS KMS, or Vault
  Transit (the `wrap`/`unwrap` trio maps 1:1 onto each provider's
  encrypt/decrypt/`GetCryptoKeyVersion` surface). The test/dev binding
  is `AshA2A.Security.KMS.Local` — a real harness process holding real
  key material and doing real AES-256-GCM via `:crypto`; zero mocks.

  ## Fail-closed contract

  Every failure mode returns `{:error, term}`. Callers
  (`AshA2A.Security.KeyManager`) translate every error into a typed
  refusal — KMS unavailability never falls back to plaintext or to
  locally-held key material.
  """

  @type kek_id :: String.t()
  @type kek_version_id :: pos_integer()
  @type dek :: <<_::256>>

  @callback wrap(kek_id(), dek()) ::
              {:ok, wrapped_dek :: binary(), kek_version_id()} | {:error, term()}

  @callback unwrap(kek_id(), wrapped_dek :: binary(), kek_version_id()) ::
              {:ok, dek()} | {:error, term()}

  @callback current_version(kek_id()) :: {:ok, kek_version_id()} | {:error, term()}

  @callback rotate_version(kek_id()) :: {:ok, kek_version_id()} | {:error, term()}
end
