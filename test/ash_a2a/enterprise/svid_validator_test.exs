# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.SvidValidatorTest do
  @moduledoc """
  FR-01.2 court for `AshA2A.SPIFFE.SvidValidator`: real certificates (leaf +
  intermediate + trust bundle) generated with `:public_key`, driven through the
  real Plug test adapter's peer-data injection. Zero mocks.
  """

  use ExUnit.Case, async: false

  alias AshA2A.SPIFFE.SvidValidator

  @trust_domain "example.org"

  # -- Real trust-bundle source (Agent-backed: a real collaborator) --------------

  defmodule BundleSource do
    @name __MODULE__

    def start_link, do: Agent.start_link(fn -> %{} end, name: @name)

    def put(bundle), do: Agent.update(@name, fn _ -> bundle end)

    def bundle, do: Agent.get(@name, & &1)
  end

  # -- Real certificate manufacture (:public_key) --------------------------------

  defmodule CertFactory do
    @moduledoc false

    def san_ext(uris) do
      {:Extension, {2, 5, 29, 17}, false,
       Enum.map(uris, fn uri -> {:uniformResourceIdentifier, String.to_charlist(uri)} end)}
    end

    def dns_ext(name) do
      {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(name)}]}
    end

    def date(offset_days) do
      d = Date.add(Date.utc_today(), offset_days)
      {d.year, d.month, d.day}
    end

    @doc "Generates a real {leaf_der, intermediate_der, root_der} chain."
    def chain(san_uris, peer_validity) do
      peer_opts =
        [
          digest: :sha256,
          extensions:
            Enum.concat([
              if(san_uris == [], do: [], else: [san_ext(san_uris)]),
              [dns_ext("svid-validator-court.test")]
            ])
        ] ++ if(peer_validity, do: [validity: peer_validity], else: [])

      [cert: leaf, key: _, cacerts: [root, intermediate, _duplicate_root]] =
        :public_key.pkix_test_data(%{
          root: [digest: :sha256],
          intermediates: [[digest: :sha256]],
          peer: peer_opts
        })

      {leaf, intermediate, root}
    end
  end

  # -- Plug harness (real Plug test adapter, peer-data injection) ----------------

  defp call_plug(ssl_cert, opts_overrides \\ []) do
    peer_data = %{address: {127, 0, 0, 1}, port: 111_317, ssl_cert: ssl_cert}
    base = %Plug.Conn{adapter: {Plug.Adapters.Test.Conn, %{peer_data: peer_data}}}
    conn = Plug.Adapters.Test.Conn.conn(base, :get, "/tasks", nil)

    opts =
      SvidValidator.init(
        [trust_domain: @trust_domain, bundle_source: BundleSource] ++ opts_overrides
      )

    SvidValidator.call(conn, opts)
  end

  defp refusal_reason(conn) do
    {status, _headers, body} = Plug.Test.sent_resp(conn)
    assert %{"error" => "spiffe_svid_refused", "reason" => reason} = Jason.decode!(body)
    {status, reason}
  end

  setup do
    start_supervised!({Agent, {fn -> %{} end, [name: BundleSource]}})
    :ok
  end

  # -- Courts ----------------------------------------------------------------------

  describe "valid SVID" do
    test "passes and stamps the verified workload identity into conn.assigns" do
      {leaf, inter, root} =
        CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put(
        {:ok,
         %{
           trust_domain: @trust_domain,
           root_certificates: [root],
           intermediate_certificates: [inter]
         }}
      )

      conn = call_plug(leaf)

      refute conn.halted
      assert is_nil(conn.status)

      assert %AshA2A.SPIFFE.AttestedIdentity{} = attested = conn.assigns[:spiffe_identity]
      assert attested.identity.uri == "spiffe://#{@trust_domain}/ns/prod/sa/checker"
      assert attested.identity.trust_domain == @trust_domain
      assert attested.svid_type == :x509
      assert attested.bundle_digest == Base.encode16(:crypto.hash(:sha256, root), case: :lower)
      assert attested.observed_at <= System.system_time(:millisecond)

      assert {:ok, %{trust_domain: @trust_domain, namespace: "prod", service_account: "checker"}} =
               SvidValidator.workload(attested.identity)

      assert SvidValidator.get_spiffe_identity(conn) == attested
    end

    test "honors the :assign option" do
      {leaf, inter, root} =
        CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      conn = call_plug(leaf, assign: :workload_identity)
      assert %AshA2A.SPIFFE.AttestedIdentity{} = conn.assigns[:workload_identity]
      assert is_nil(conn.assigns[:spiffe_identity])
    end
  end

  describe "fail-closed refusals" do
    test "missing client certificate -> 401 missing_svid" do
      {leaf, inter, root} =
        CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "missing_svid"} = refusal_reason(call_plug(nil))
    end

    test "malformed SVID bytes -> 401 svid_malformed" do
      assert {401, "svid_malformed"} = refusal_reason(call_plug(<<0, 1, 2, 3, "not a certificate">>))
    end

    test "expired SVID -> 401 svid_expired" do
      {leaf, inter, root} =
        CertFactory.chain(
          ["spiffe://#{@trust_domain}/ns/prod/sa/checker"],
          {CertFactory.date(-9), CertFactory.date(-2)}
        )

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "svid_expired"} = refusal_reason(call_plug(leaf))
    end

    test "SVID not chaining to the bundle root -> 401 svid_untrusted" do
      # Leaf + intermediate from an independent root, offered against our bundle.
      {leaf, inter, _foreign_root} =
        CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      {our_leaf, _our_inter, our_root} = CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/x"], nil)

      BundleSource.put(
        {:ok,
         %{
           trust_domain: @trust_domain,
           root_certificates: [our_root],
           intermediate_certificates: [inter]
         }}
      )

      assert {401, "svid_untrusted"} = refusal_reason(call_plug(leaf))
      assert is_binary(our_leaf)
    end

    test "wrong trust domain in the SPIFFE ID -> 401 trust_domain_mismatch" do
      {leaf, inter, root} =
        CertFactory.chain(["spiffe://other-domain.example/ns/prod/sa/checker"], nil)

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "trust_domain_mismatch"} = refusal_reason(call_plug(leaf))
    end

    test "no SPIFFE URI SAN -> 401 svid_identity_absent" do
      {leaf, inter, root} = CertFactory.chain([], nil)

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "svid_identity_absent"} = refusal_reason(call_plug(leaf))
    end

    test "multiple SPIFFE URIs -> 401 svid_multiple_uris" do
      {leaf, inter, root} =
        CertFactory.chain(
          [
            "spiffe://#{@trust_domain}/ns/prod/sa/checker",
            "spiffe://#{@trust_domain}/ns/dev/sa/other"
          ],
          nil
        )

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "svid_multiple_uris"} = refusal_reason(call_plug(leaf))
    end

    test "non /ns/<ns>/sa/<sa> identity path -> 401 identity_path_invalid" do
      {leaf, inter, root} = CertFactory.chain(["spiffe://#{@trust_domain}/scheduler"], nil)

      BundleSource.put(
        {:ok,
         %{trust_domain: @trust_domain, root_certificates: [root], intermediate_certificates: [inter]}}
      )

      assert {401, "identity_path_invalid"} = refusal_reason(call_plug(leaf))
    end
  end

  describe "trust-bundle faults (fail-closed, 503)" do
    test "bundle source returns an error -> 503 trust_bundle_unavailable" do
      {leaf, _inter, _root} = CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put({:error, :rotating})
      assert {503, "trust_bundle_unavailable"} = refusal_reason(call_plug(leaf))
    end

    test "bundle source module not loaded -> 503 bundle_source_unavailable" do
      {leaf, _inter, _root} = CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      assert {503, "bundle_source_unavailable"} =
               refusal_reason(call_plug(leaf, bundle_source: NoSuchBundleSource))
    end

    test "empty root set -> 503 trust_bundle_empty" do
      {leaf, _inter, _root} = CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put({:ok, %{trust_domain: @trust_domain, root_certificates: []}})
      assert {503, "trust_bundle_empty"} = refusal_reason(call_plug(leaf))
    end

    test "bundle without trust domain -> 503 trust_bundle_unavailable" do
      {leaf, _inter, _root} = CertFactory.chain(["spiffe://#{@trust_domain}/ns/prod/sa/checker"], nil)

      BundleSource.put({:ok, %{root_certificates: [<<1, 2, 3>>]}})
      assert {503, "trust_bundle_unavailable"} = refusal_reason(call_plug(leaf))
    end
  end

  describe "workload/1 helper" do
    test "parses ns/sa segments" do
      {:ok, identity} = AshA2A.SPIFFE.Identity.parse("spiffe://td.example/ns/blue/sa/web")

      assert {:ok, %{trust_domain: "td.example", namespace: "blue", service_account: "web"}} =
               SvidValidator.workload(identity)
    end

    test "rejects non-workload paths and non-identities" do
      {:ok, identity} = AshA2A.SPIFFE.Identity.parse("spiffe://td.example/database")
      assert {:error, :identity_path_invalid} = SvidValidator.workload(identity)
      assert {:error, :identity_path_invalid} = SvidValidator.workload("not an identity")
    end
  end

  describe "init/1 validation" do
    test "requires :trust_domain" do
      assert_raise ArgumentError, ~r/:trust_domain/, fn ->
        SvidValidator.init(bundle_source: BundleSource)
      end
    end

    test "requires binary :trust_domain" do
      assert_raise ArgumentError, ~r/:trust_domain/, fn ->
        SvidValidator.init(trust_domain: :atom_domain, bundle_source: BundleSource)
      end
    end

    test "requires module :bundle_source" do
      assert_raise ArgumentError, ~r/:bundle_source/, fn ->
        SvidValidator.init(trust_domain: "example.org", bundle_source: "nope")
      end
    end
  end
end
