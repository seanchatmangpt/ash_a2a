defmodule AshA2A.SPIFFE.IdentityTest do
  use ExUnit.Case, async: true
  alias AshA2A.SPIFFE.{AttestedIdentity, Identity}

  test "parses trust-domain qualified SPIFFE identity" do
    assert {:ok, identity} = Identity.parse("spiffe://prod.example/pdp/authzen")
    assert identity.trust_domain == "prod.example"
    assert identity.path == "/pdp/authzen"
  end

  test "rejects query and fragment confusion" do
    assert {:error, :spiffe_query_fragment_forbidden} =
             Identity.parse("spiffe://prod.example/pdp?role=admin")
  end

  test "attested identity requires verifier-produced bundle evidence" do
    assert {:ok, attested} =
             AttestedIdentity.from_verified("spiffe://prod.example/pdp/authzen",
               svid_type: :x509,
               bundle_digest: "sha256:bundle",
               observed_at: 10
             )
    assert attested.svid_type == :x509
  end
end
