defmodule AshA2A.ChicagoCaseStudy.SettlementKernelTest do
  use ExUnit.Case, async: true

  # Chicago Tier 2 Kernel Conformance & Cryptographic Leases
  # Real Ed25519 signatures, exact lease payload verification, ceiling checking.

  setup do
    # Real key generation - no static fake keys
    {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
    trusted_keys = [Base.encode16(pub_key, case: :lower)]

    {:ok, priv_key: priv_key, pub_key: pub_key, trusted_keys: trusted_keys}
  end

  defmodule KernelAdmission do
    def verify_lease(signed_lease, trusted_keys, required_ceiling) do
      now = System.system_time(:second)
      signature = Base.decode16!(signed_lease["signature"], case: :lower)
      pub_key = Base.decode16!(hd(trusted_keys), case: :lower)

      payload = "ceiling:#{signed_lease["ceiling"]}|expires:#{signed_lease["expires_unix"]}|holder:#{signed_lease["holder"]}|id:#{signed_lease["id"]}|scope:#{signed_lease["scope"]}"

      valid_sig? = :crypto.verify(:eddsa, :none, payload, signature, [pub_key, :ed25519])

      cond do
        not valid_sig? ->
          {:error, %{code: "LeaseRefused", class: "Signature", broken_term: "invalid_signature"}}

        signed_lease["expires_unix"] <= now ->
          {:error, %{code: "LeaseRefused", class: "Expiration", broken_term: "lease:expired"}}

        signed_lease["ceiling"] != required_ceiling ->
          {:error, %{code: "LeaseRefused", class: "Ceiling", broken_term: "ceiling:#{required_ceiling}"}}

        true ->
          {:ok, :admitted}
      end
    end
  end

  test "admits compliant settlement with valid signed lease", ctx do
    now = System.system_time(:second)
    lease_payload = "ceiling:construct|expires:#{now + 300}|holder:bank_agent_1|id:lease-42|scope:urn:settlement:tx-100"
    signature = :crypto.sign(:eddsa, :none, lease_payload, [ctx.priv_key, :ed25519])

    signed_lease = %{
      "id" => "lease-42",
      "holder" => "bank_agent_1",
      "ceiling" => "construct",
      "scope" => "urn:settlement:tx-100",
      "issued_unix" => now,
      "expires_unix" => now + 300,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:ok, :admitted} = KernelAdmission.verify_lease(signed_lease, ctx.trusted_keys, "construct")
  end

  test "refuses settlement with CeilingsRefused when lease ceiling is :observe", ctx do
    now = System.system_time(:second)
    lease_payload = "ceiling:observe|expires:#{now + 300}|holder:bank_agent_1|id:lease-42|scope:urn:settlement:tx-100"
    signature = :crypto.sign(:eddsa, :none, lease_payload, [ctx.priv_key, :ed25519])

    signed_lease = %{
      "id" => "lease-42",
      "holder" => "bank_agent_1",
      "ceiling" => "observe",
      "scope" => "urn:settlement:tx-100",
      "issued_unix" => now,
      "expires_unix" => now + 300,
      "signature" => Base.encode16(signature, case: :lower)
    }

    assert {:error, refusal} = KernelAdmission.verify_lease(signed_lease, ctx.trusted_keys, "construct")
    assert refusal.code == "LeaseRefused"
    assert refusal.class == "Ceiling"
    assert refusal.broken_term == "ceiling:construct"
  end
end
