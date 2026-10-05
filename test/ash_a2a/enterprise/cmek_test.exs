# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.CMEKTest do
  use ExUnit.Case, async: false

  alias AshA2A.Security.CMEK
  alias AshA2A.Security.KeyManager
  alias AshA2A.Security.KMS.Local

  @plaintext "task-parameters::" <> Base.encode16(:crypto.strong_rand_bytes(16))

  setup do
    Local.ensure_started()
    Application.put_env(:ash_a2a, :cmek_kms_client, Local)
    Application.delete_env(:ash_a2a, :cmek_kek_id)

    on_exit(fn ->
      Local.stop()
      Application.delete_env(:ash_a2a, :cmek_kms_client)
      Application.delete_env(:ash_a2a, :cmek_kek_id)
    end)

    :ok
  end

  # --- court 1: full envelope cycle (FR-03.1/FR-03.2) ---

  test "envelope cycle encrypts under an ephemeral DEK and decrypts back" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)

    # ARD §3.3 step 4: persisted set is present and well-formed.
    assert is_binary(envelope.ciphertext) and byte_size(envelope.ciphertext) > 0
    assert is_binary(envelope.wrapped_dek) and byte_size(envelope.wrapped_dek) >= 29
    assert is_binary(envelope.iv) and byte_size(envelope.iv) == 12
    assert is_binary(envelope.tag) and byte_size(envelope.tag) == 16
    assert is_integer(envelope.kek_version_id) and envelope.kek_version_id >= 1

    # The plaintext is not in the envelope in the clear.
    assert envelope.ciphertext != @plaintext
    assert plaintext_absent?(@plaintext, envelope)

    # Round trip through the KMS unwrap path.
    assert {:ok, @plaintext} = KeyManager.decrypt(envelope)
  end

  test "DEKs are 256-bit, crypto-secure, and never repeated" do
    dek1 = CMEK.generate_dek()
    dek2 = KeyManager.generate_dek()

    assert byte_size(dek1) == 32
    assert byte_size(dek2) == 32
    assert dek1 != dek2
  end

  test "two envelopes of the same plaintext differ (fresh DEK + IV per message)" do
    assert {:ok, env1} = KeyManager.encrypt(@plaintext)
    assert {:ok, env2} = KeyManager.encrypt(@plaintext)

    assert env1.ciphertext != env2.ciphertext
    assert env1.wrapped_dek != env2.wrapped_dek
    assert env1.iv != env2.iv

    assert {:ok, @plaintext} = KeyManager.decrypt(env1)
    assert {:ok, @plaintext} = KeyManager.decrypt(env2)
  end

  # --- court 2: rotation without payload rewrite (FR-03.3) ---

  test "rotation re-wraps the DEK and leaves ciphertext, iv, and tag byte-identical" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    old_ciphertext = envelope.ciphertext
    old_iv = envelope.iv
    old_tag = envelope.tag
    old_wrapped = envelope.wrapped_dek
    old_version = envelope.kek_version_id

    assert {:ok, rotated} = KeyManager.rotate(envelope)

    # Payload bytes untouched by rotation.
    assert rotated.ciphertext == old_ciphertext
    assert rotated.iv == old_iv
    assert rotated.tag == old_tag

    # KEK wrap moved to a new version.
    assert rotated.wrapped_dek != old_wrapped
    assert rotated.kek_version_id == old_version + 1
    assert {:ok, version} = Local.current_version(KeyManager.default_kek_id())
    assert version == rotated.kek_version_id

    # The rotated envelope decrypts; the legacy envelope still decrypts
    # under its retained KEK version.
    assert {:ok, @plaintext} = KeyManager.decrypt(rotated)
    assert {:ok, @plaintext} = KeyManager.decrypt(envelope)
  end

  test "rotation across multiple KEK versions keeps decrypting the same ciphertext" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    ciphertext = envelope.ciphertext

    {:ok, _} = KeyManager.rotate(envelope)
    {:ok, envelope} = KeyManager.rotate(envelope)
    {:ok, envelope} = KeyManager.rotate(envelope)

    assert envelope.ciphertext == ciphertext
    assert {:ok, @plaintext} = KeyManager.decrypt(envelope)
  end

  # --- court 3: tamper is a typed refusal, not a crash ---

  test "flipping a ciphertext byte refuses with :refused_cmek_tamper_detected" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    tampered = %{envelope | ciphertext: flip_byte(envelope.ciphertext)}

    assert {:error, :refused_cmek_tamper_detected, detail} = KeyManager.decrypt(tampered)
    assert detail =~ "authentication failed"
  end

  test "flipping a tag byte refuses with :refused_cmek_tamper_detected" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    tampered = %{envelope | tag: flip_byte(envelope.tag)}

    assert {:error, :refused_cmek_tamper_detected, _} = KeyManager.decrypt(tampered)
  end

  test "a swapped IV refuses with :refused_cmek_tamper_detected" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    other = %{envelope | iv: :crypto.strong_rand_bytes(12)}

    assert {:error, :refused_cmek_tamper_detected, _} = KeyManager.decrypt(other)
  end

  test "a tampered or truncated wrapped_dek refuses with :refused_cmek_unwrap_failed" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)

    tampered = %{envelope | wrapped_dek: flip_byte(envelope.wrapped_dek)}
    assert {:error, :refused_cmek_unwrap_failed, detail} = KeyManager.decrypt(tampered)
    assert detail =~ "unwrap"

    truncated = %{envelope | wrapped_dek: binary_part(envelope.wrapped_dek, 0, 10)}
    assert {:error, :refused_cmek_unwrap_failed, _} = KeyManager.decrypt(truncated)

    unknown_version = %{envelope | kek_version_id: 9_999}
    assert {:error, :refused_cmek_unwrap_failed, _} = KeyManager.decrypt(unknown_version)
  end

  test "a malformed envelope refuses with :refused_cmek_invalid_envelope" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)

    assert {:error, :refused_cmek_invalid_envelope, _} =
             KeyManager.decrypt(Map.delete(envelope, :tag))

    assert {:error, :refused_cmek_invalid_envelope, _} =
             KeyManager.decrypt(%{envelope | iv: :crypto.strong_rand_bytes(11)})

    assert {:error, :refused_cmek_invalid_envelope, _} =
             KeyManager.decrypt(%{envelope | kek_version_id: 0})

    assert {:error, :refused_cmek_invalid_envelope, _} = KeyManager.decrypt("not-a-map")
  end

  # --- court 4: KMS-down fails closed, no plaintext fallback ---

  test "no KMS client configured refuses every operation with :refused_cmek_kms_unavailable" do
    Application.delete_env(:ash_a2a, :cmek_kms_client)

    assert {:error, :refused_cmek_kms_unavailable, detail} = KeyManager.encrypt(@plaintext)
    assert detail =~ "fail-closed"

    assert {:error, :refused_cmek_kms_unavailable, _} = KeyManager.decrypt(%{})
    assert {:error, :refused_cmek_kms_unavailable, _} = KeyManager.rotate(%{})
  end

  test "a stopped KMS harness refuses encrypt, decrypt, and rotate fail-closed" do
    assert {:ok, envelope} = KeyManager.encrypt(@plaintext)
    Local.stop()

    assert {:error, :refused_cmek_kms_unavailable, _} = KeyManager.encrypt(@plaintext)

    assert {:error, :refused_cmek_kms_unavailable, _} = KeyManager.decrypt(envelope)

    assert {:error, :refused_cmek_kms_unavailable, _} = KeyManager.rotate(envelope)

    # No plaintext fallback: the refusal is typed, never a payload.
    refute match?({:ok, _}, KeyManager.decrypt(envelope))
  end

  test "opts :kms_client overrides configuration" do
    # A client configured that cannot serve the KEK: unwrap must fail.
    Application.put_env(:ash_a2a, :cmek_kms_client, OtherKmsStub)

    assert {:ok, envelope} = KeyManager.encrypt(@plaintext, kms_client: Local)

    assert {:error, :refused_cmek_unwrap_failed, _} =
             KeyManager.decrypt(envelope, kms_client: OtherKmsStub)

    # Explicit opts win over the configured default.
    assert {:ok, @plaintext} = KeyManager.decrypt(envelope, kms_client: Local)
  end

  defmodule OtherKmsStub do
    @behaviour AshA2A.Security.KMS.Client

    @impl true
    def wrap(_kek_id, _dek), do: {:error, :other_tenancy}

    @impl true
    def unwrap(_kek_id, _wrapped, _version), do: {:error, :other_tenancy}

    @impl true
    def current_version(_kek_id), do: {:error, :other_tenancy}
  end

  # --- helpers ---

  defp flip_byte(binary) do
    <<head::binary-size(8), byte::binary-size(1), tail::binary>> = binary
    <<head::binary, :erlang.bxor(byte, <<0x01>>)::binary, tail::binary>>
  end

  defp plaintext_absent?(plaintext, envelope) do
    Enum.all?(
      [envelope.ciphertext, envelope.wrapped_dek, envelope.iv, envelope.tag],
      fn blob -> :binary.match(blob, plaintext) == :nomatch end
    )
  end
end
