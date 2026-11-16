# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: Attestation, Receipt Store & DFCM
# Contains 23 original test files:
#   - test/ash_a2a/crypto_standing/certificate_verifier_test.exs
#   - test/ash_a2a/dfcm/court_test.exs
#   - test/ash_a2a/dfcm/fleet_intake_test.exs
#   - test/ash_a2a/dfcm/generated_drift_test.exs
#   - test/ash_a2a/dfcm/generated_projection_test.exs
#   - test/ash_a2a/dfcm/reverse_chesterton_test.exs
#   - test/ash_a2a/durable_claim_store/durable_file_test.exs
#   - test/ash_a2a/durable_conformance/strict_c1_checks_test.exs
#   - test/ash_a2a/durable_prepared_journal/journal_test.exs
#   - test/ash_a2a/evidence/affidavit_test.exs
#   - test/ash_a2a/graph_law/subprocess_test.exs
#   - test/ash_a2a/graph_law/unpinned_refusal_test.exs
#   - test/ash_a2a/graph_law/wasmex_host_hardening_test.exs
#   - test/ash_a2a/graph_law/wasmtime_runtime_test.exs
#   - test/ash_a2a/receipt_store/actuation_claim_lease_test.exs
#   - test/ash_a2a/receipt_store/boot_check_test.exs
#   - test/ash_a2a/receipt_store/store_hardening_test.exs
#   - test/ash_a2a/research/erc_sanitize_test.exs
#   - test/ash_a2a/sa2a/conformance/mix_project_stack_test.exs
#   - test/ash_a2a/sa2a/conformance/profiles_test.exs
#   - test/attestation/attestation_gate_test.exs
#   - test/attestation/gate_grant_allowlist_test.exs
#   - test/attestation/lane01_hardening_test.exs
# ==============================================================================

# --- SECTION 1: Original test/ash_a2a/crypto_standing/certificate_verifier_test.exs ---
defmodule AshA2A.CryptoStanding.CertificateVerifierTest do
  @moduledoc """
  Courts for `AshA2A.C2.CertificateVerifier`: every signature on a certificate is
  verified through `AshA2A.CryptoStanding` (Sa2aCrypto). DB-free, Chicago style: real
  keys, real `:crypto` signatures as the oracle, real registry view, no mocks.
  """
  use ExUnit.Case, async: true

  alias AshA2A.C2.{Certificate, CertificateVerifier, PreparedEffect}
  alias Sa2aCrypto.{KeyRecord, KeyRef, Registry.Static, SignedMessage}

  @now 1_800_000_000
  @audience "actuator:kernel-1"

  defp effect(payload \\ %{n: 1}),
    do: PreparedEffect.new("principal-1", "cap", "subject", payload)

  defp key(alg \\ "ES256", opts \\ []) do
    {pub, priv} =
      case alg do
        "ES256" -> :crypto.generate_key(:ecdh, :secp256r1)
        "EdDSA" -> :crypto.generate_key(:eddsa, :ed25519)
        "ML-DSA-65" -> :crypto.generate_key(:mldsa65, [])
      end

    kid = KeyRef.kid!(alg, pub)

    rec =
      struct!(
        KeyRecord,
        Keyword.merge(
          [
            kid: kid,
            alg: alg,
            public_key: pub,
            custodian_id: "cust-#{kid}",
            custody_tier: :i2,
            state: :active,
            revocation_epoch: 0
          ],
          opts
        )
      )

    %{alg: alg, kid: kid, priv: priv, rec: rec}
  end

  defp raw_sign("ES256", m, k), do: :crypto.sign(:ecdsa, :sha256, m, [k, :secp256r1])
  defp raw_sign("EdDSA", m, k), do: :crypto.sign(:eddsa, :none, m, [k, :ed25519])
  defp raw_sign("ML-DSA-65", m, k), do: :crypto.sign(:mldsa65, :none, m, k)

  defp fields(e, k, over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "alg" => k.alg,
        "kid" => k.kid,
        "effect_digest" => e.digest,
        "principal" => e.principal,
        "policy_epoch" => 5,
        "revocation_epoch" => 2,
        "generation" => 9,
        "nonce" => "n-#{k.kid}",
        "not_before" => @now - 10,
        "expires" => @now + 100,
        "audience" => @audience
      },
      over
    )
  end

  # a real signature over the domain-separated message (oracle: :crypto.sign)
  defp sign(e, k, over \\ %{}) do
    {:ok, bytes} = SignedMessage.build(fields(e, k, over))

    %{
      signer: k.kid,
      kid: k.kid,
      alg: k.alg,
      nonce: "n-#{k.kid}",
      signature: raw_sign(k.alg, bytes, k.priv)
    }
  end

  defp cert(e, sigs, over \\ %{}) do
    struct!(
      Certificate,
      Map.merge(
        %{
          effect_digest: e.digest,
          principal: e.principal,
          policy_epoch: 5,
          revocation_epoch: 2,
          generation: 9,
          signatures: sigs,
          version: 1,
          nonce: "cert-level-nonce",
          threshold: 1,
          not_before_ms: (@now - 10) * 1000,
          expires_at_ms: (@now + 100) * 1000,
          audience: @audience
        },
        over
      )
    )
  end

  defp ctx(keys, over \\ %{}) do
    Map.merge(
      %{
        policy_epoch: 5,
        revocation_epoch: 2,
        generation: 9,
        principal: "principal-1",
        registry: Static.view(Enum.map(keys, & &1.rec)),
        audience: @audience,
        now: @now
      },
      over
    )
  end

  describe "garbage signatures (the defect: algorithm-atom-only check)" do
    test "legacy-shaped signature with a supported algorithm atom and garbage bytes is refused" do
      e = effect()
      k = key("EdDSA")
      sig = %{signer: "s1", algorithm: :eddsa, signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))
    end

    test "registered kid, right alg, random 64 garbage bytes is refused" do
      e = effect()
      k = key("EdDSA")
      sig = %{sign(e, k) | signature: :crypto.strong_rand_bytes(64)}

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))

      assert {:error, {:certificate_refused, [{:invalid, :bad_signature}]}} =
               CertificateVerifier.standings(cert(e, [sig]), e, ctx([k]))
    end

    test "empty and missing signatures are refused" do
      e = effect()
      k = key()
      assert {:error, :certificate_refused} = CertificateVerifier.verify(cert(e, []), e, ctx([k]))
    end

    test "one valid + one garbage signature is refused (every signature is verified)" do
      e = effect()
      good = key("ES256")
      bad = key("EdDSA")
      sigs = [sign(e, good), %{sign(e, bad) | signature: :crypto.strong_rand_bytes(64)}]

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, sigs), e, ctx([good, bad]))
    end
  end

  describe "valid certificates" do
    test "ES256, EdDSA and ML-DSA-65 signatures verify" do
      for alg <- ["ES256", "EdDSA", "ML-DSA-65"] do
        e = effect()
        k = key(alg)
        profile = if alg == "ML-DSA-65", do: :pqc, else: :classical
        c = ctx([k], %{required_profile: profile})
        assert :ok = CertificateVerifier.verify(cert(e, [sign(e, k)]), e, c), alg
      end
    end

    test "two custodians: standings carry custodian, tier, epoch and the (kid, nonce) replay key" do
      e = effect()
      a = key("ES256", custodian_id: "org-a", custody_tier: :i3, revocation_epoch: 4)
      b = key("EdDSA", custodian_id: "org-b", custody_tier: :i4)

      assert {:ok, [x, y]} =
               CertificateVerifier.standings(cert(e, [sign(e, a), sign(e, b)]), e, ctx([a, b]))

      assert {:valid, %{custodian_id: "org-a", tier: :i3, epoch: 4}} = x.standing
      assert {:valid, %{custodian_id: "org-b", tier: :i4}} = y.standing
      assert x.replay_key == {a.kid, "n-#{a.kid}"}
    end

    test "the certificate-level kid/alg/nonce apply when a signature entry omits them" do
      e = effect()
      k = key("EdDSA")
      s = sign(e, k)

      c =
        cert(e, [%{signer: "s", signature: s.signature}], %{
          kid: k.kid,
          alg: k.alg,
          nonce: s.nonce
        })

      assert :ok = CertificateVerifier.verify(c, e, ctx([k]))
    end
  end

  describe "the verifier recomputes from durable state, never the certificate body" do
    test "signature over another effect's digest is refused although the certificate claims this effect" do
      e = effect(%{n: 1})
      other = effect(%{n: 2})
      k = key()
      sig = sign(other, k)

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(cert(e, [sig]), e, ctx([k]))
    end

    test "each signed field, changed after signing, is refused" do
      e = effect()
      k = key()
      good = sign(e, k)
      c = ctx([k])

      mutations = [
        {%{policy_epoch: 6}, %{policy_epoch: 6}},
        {%{revocation_epoch: 3}, %{revocation_epoch: 3}},
        {%{generation: 10}, %{generation: 10}},
        {%{audience: "actuator:other"}, %{}},
        {%{not_before_ms: (@now - 11) * 1000}, %{}},
        {%{expires_at_ms: (@now + 101) * 1000}, %{}},
        {%{version: 2}, %{}}
      ]

      for {cert_over, ctx_over} <- mutations do
        assert {:error, :certificate_refused} =
                 CertificateVerifier.verify(cert(e, [good], cert_over), e, Map.merge(c, ctx_over)),
               inspect(cert_over)
      end
    end
  end

  describe "context and key standing are enforced" do
    test "no registry in ctx fails closed" do
      e = effect()
      k = key()

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(
                 cert(e, [sign(e, k)]),
                 e,
                 Map.delete(ctx([k]), :registry)
               )
    end

    test "wrong / missing audience, expired, not yet valid" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{audience: "x"}))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, Map.delete(ctx([k]), :audience))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{now: @now + 100}))

      assert {:error, :certificate_refused} =
               CertificateVerifier.verify(c, e, ctx([k], %{now: @now - 11}))

      assert :ok = CertificateVerifier.verify(c, e, ctx([k]))
    end

    test "unknown kid and every non-active key state are refused" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])
      assert {:error, :certificate_refused} = CertificateVerifier.verify(c, e, ctx([key()]))

      for state <- KeyRecord.states() -- [:active] do
        kk = key("ES256", state: state)

        assert {:error, :certificate_refused} =
                 CertificateVerifier.verify(cert(e, [sign(e, kk)]), e, ctx([kk])),
               "#{state}"
      end
    end

    test "downgrade: a pqc-required context refuses a classical certificate" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)])

      assert {:error, {:certificate_refused, [{:invalid, :profile_downgrade}]}} =
               CertificateVerifier.standings(c, e, ctx([k], %{required_profile: :pqc}))
    end

    test "mediation still runs first (unbound effect is refused before crypto)" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)], %{principal: "someone-else"})
      assert {:error, :refused} = CertificateVerifier.standings(c, e, ctx([k]))
    end
  end

  describe "canonical certificate time model (milliseconds struct, seconds signed message)" do
    test "to_seconds/from_seconds round-trip whole seconds and refuse sub-second values" do
      assert {:ok, 1_800_000_000} = Certificate.to_seconds(1_800_000_000_000)
      assert Certificate.from_seconds(1_800_000_000) == 1_800_000_000_000
      assert {:error, :sub_second_time} = Certificate.to_seconds(1_800_000_000_001)
      assert {:error, :bad_time} = Certificate.to_seconds(-1)
      assert {:error, :bad_time} = Certificate.to_seconds("1")
    end

    test "a sub-second validity bound is refused rather than truncated (would change the signed bytes)" do
      e = effect()
      k = key()
      c = cert(e, [sign(e, k)], %{expires_at_ms: (@now + 100) * 1000 + 1})

      assert {:error, {:certificate_refused, [{:invalid, :malformed_certificate}]}} =
               CertificateVerifier.standings(c, e, ctx([k]))
    end

    test "the message a signer signs over the seconds form verifies over the ms struct" do
      e = effect()
      k = key()
      {:ok, {nb, ex}} = Certificate.window_seconds(cert(e, []))
      assert {nb, ex} == {@now - 10, @now + 100}
      assert :ok = CertificateVerifier.verify(cert(e, [sign(e, k)]), e, ctx([k]))
    end
  end

  describe "AshA2A.CryptoStanding adapter" do
    alias AshA2A.CryptoStanding

    test "delegates to Sa2aCrypto: valid standing and typed refusal" do
      e = effect()
      k = key()
      s = sign(e, k)
      {:ok, bytes} = CryptoStanding.signed_message(fields(e, k))

      env = %Sa2aCrypto.Envelope{
        v: 1,
        alg: k.alg,
        kid: k.kid,
        profile: :classical,
        signed_bytes_digest: SignedMessage.digest(bytes),
        signature: s.signature,
        nonce: s.nonce,
        not_before: @now - 10,
        expires: @now + 100,
        audience: @audience
      }

      view = Static.view([k.rec])
      opts = [now: @now, audience: @audience]
      assert {:valid, %{kid: kid}} = CryptoStanding.verify(env, bytes, view, opts)
      assert kid == k.kid

      assert {:invalid, :wrong_audience} =
               CryptoStanding.verify(env, bytes, view, now: @now, audience: "z")
    end
  end

  describe "AshA2A.C2.CryptoVerifier" do
    alias AshA2A.C2.CryptoVerifier

    test "real EdDSA verifies; wrong-size and garbage keys are errors, never raises" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      sig = :crypto.sign(:eddsa, :none, "m", [priv, :ed25519])
      assert CryptoVerifier.verify(:eddsa, "m", sig, pub) == true
      assert CryptoVerifier.verify(:eddsa, "m!", sig, pub) == {:error, :bad_signature}
      assert CryptoVerifier.verify(:eddsa, "m", sig, <<1, 2>>) == {:error, :bad_key}
      assert CryptoVerifier.verify(:eddsa, "m", sig, nil) == {:error, :bad_key}
    end

    test ":es256 verifies through the same provider; placeholders map to real OTP atoms" do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
      sig = :crypto.sign(:ecdsa, :sha256, "m", [priv, :secp256r1])
      assert CryptoVerifier.verify(:es256, "m", sig, pub) == true
      assert CryptoVerifier.verify(:es256, "m", sig, <<4, 1>>) == {:error, :bad_key}

      {mpub, mpriv} = :crypto.generate_key(:mldsa65, [])
      msig = :crypto.sign(:mldsa65, :none, "m", mpriv)
      assert CryptoVerifier.otp_atom(:ml_dsa) == :mldsa65
      assert CryptoVerifier.otp_atom(:slh_dsa) == :slh_dsa_sha2_128s
      assert CryptoVerifier.verify(:ml_dsa, "m", msig, mpub) == true
      assert CryptoVerifier.verify(:ml_dsa, "m", msig, <<1>>) == {:error, :bad_key}
      assert CryptoVerifier.supported?(:ml_dsa) and CryptoVerifier.supported?(:slh_dsa)
      refute CryptoVerifier.supported?(:rsa)
      assert CryptoVerifier.verify(:rsa, "m", "s", "k") == {:error, :unsupported_algorithm}
    end
  end
end

# --- SECTION 2: Original test/ash_a2a/dfcm/court_test.exs ---
defmodule AshA2A.DfCM.CourtTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.{Court, FleetIntake}

  test "every donor has one exact-subject negative court" do
    assert :ok = Court.validate_all()

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert {:ok, court} = Court.load(id)
      assert court["donor"] == id
      assert court["subject"] == donor["subject"]
      assert court["capability"] == donor["capability"]
      assert court["falsifier"] == donor["falsifier"]
      assert court["authority"] == "NONE"
      assert court["consequence"] == "EVIDENCE_ONLY"
      assert court["expected"] in ["REFUSED", "UNKNOWN", "UNSUPPORTED"]
    end
  end
end

# --- SECTION 3: Original test/ash_a2a/dfcm/fleet_intake_test.exs ---
defmodule AshA2A.DfCM.FleetIntakeTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "canonical fleet manifest is structurally admitted" do
    assert :ok = FleetIntake.validate()
    assert length(FleetIntake.ids()) == 15
  end

  test "every donor stays powerless at the SA2A boundary" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert donor["authority"] == "NONE"
      assert donor["consequence"] == "EVIDENCE_ONLY"
      assert donor["subject"] == donor["repository"] <> "@" <> donor["sha"]
      assert donor["reuse"] != []
      assert donor["negative_knowledge"] != []

      assert {:ok, envelope} = FleetIntake.envelope(id)
      assert envelope.standing == :candidate
      assert envelope.authority_requirement == "none"
      assert envelope.consequence_class == "none"
      assert envelope.subjects == [donor["subject"]]
    end
  end

  test "projections bind exact donor identity and refuse authority smuggling" do
    for id <- FleetIntake.ids() do
      assert {:ok, projection} = FleetIntake.project(id, %{"case" => "positive"})
      assert {:ok, ^projection} = FleetIntake.admit_projection(id, projection)

      assert {:error, %{code: :refused_dfcm_projection, field: :authority}} =
               FleetIntake.admit_projection(id, %{projection | "authority" => "DO"})

      assert {:error, %{code: :refused_dfcm_projection, field: :subject}} =
               FleetIntake.admit_projection(id, %{projection | "subject" => "repo@wrong"})
    end
  end
end

# --- SECTION 4: Original test/ash_a2a/dfcm/generated_drift_test.exs ---
defmodule AshA2A.DfCM.GeneratedDriftTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  @root Path.expand("../../..", __DIR__)

  test "generated module and court surfaces stay aligned with the manifest" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)

      module_path = Path.join([@root, "lib", "ash_a2a", "dfcm", "generated", id <> ".ex"])
      court_path = Path.join([@root, "priv", "dfcm", "fleet", "courts", id <> ".json"])

      assert File.exists?(module_path), "missing generated module for #{id}"
      assert File.exists?(court_path), "missing generated court for #{id}"

      module_text = File.read!(module_path)
      assert module_text =~ "Generated from priv/ggen/ash_a2a/dfcm/ontology.ttl"
      assert module_text =~ ~s(@donor_id "#{id}")

      court = court_path |> File.read!() |> Jason.decode!()
      assert court["subject"] == donor["subject"]
      assert court["falsifier"] == donor["falsifier"]
    end
  end

  test "canonical ontology remains the declared semantic owner" do
    manifest = FleetIntake.manifest()
    assert manifest["generated_from"] == "priv/ggen/ash_a2a/dfcm/ontology.ttl"

    ontology_path = Path.join([@root, "priv", "ggen", "ash_a2a", "dfcm", "ontology.ttl"])
    assert File.exists?(ontology_path)
    ontology = File.read!(ontology_path)

    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert ontology =~ donor["repository"]
      assert ontology =~ donor["sha"]
      assert ontology =~ donor["falsifier"]
    end
  end
end

# --- SECTION 5: Original test/ash_a2a/dfcm/generated_projection_test.exs ---
defmodule AshA2A.DfCM.GeneratedProjectionTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.Generated

  @modules [
    Generated.GraphLaw,
    Generated.Affidavit,
    Generated.AshR2RML,
    Generated.GgenCreate,
    Generated.Ferroplan,
    Generated.GymAct,
    Generated.GgenIgniter,
    Generated.GgenEcosystem,
    Generated.Wasm4pm,
    Generated.Bcinr,
    Generated.Castle,
    Generated.Xaas,
    Generated.GgenMarketplace,
    Generated.ChatmanEcosystem
  ]

  test "all generated donor modules resolve through the shared DfCM membrane" do
    assert length(@modules) == 14

    for module <- @modules do
      id = module.donor_id()
      contract = module.contract()
      assert contract["id"] == id
      assert contract["authority"] == "NONE"
      assert contract["consequence"] == "EVIDENCE_ONLY"

      assert {:ok, projection} = module.project(%{"module" => inspect(module)})
      assert projection["donor"] == id
      assert {:ok, ^projection} = module.admit_projection(projection)
    end
  end
end

# --- SECTION 6: Original test/ash_a2a/dfcm/reverse_chesterton_test.exs ---
defmodule AshA2A.DfCM.ReverseChestertonTest do
  use ExUnit.Case, async: true

  alias AshA2A.DfCM.FleetIntake

  test "every imported capability preserves mature negative knowledge" do
    for id <- FleetIntake.ids() do
      donor = FleetIntake.fetch!(id)
      assert length(donor["reuse"]) >= 1
      assert length(donor["negative_knowledge"]) >= 1
      assert is_binary(donor["falsifier"]) and donor["falsifier"] != ""
    end
  end

  test "recent universal laws and qualification algebra are references, not parallel owners" do
    universal = FleetIntake.fetch!("chatman_ecosystem")
    graphlaw = FleetIntake.fetch!("graphlaw")

    assert universal["capability"] == "universal_laws_formal_core"
    assert graphlaw["capability"] == "qualification_algebra"
    assert universal["owner"] == "chatman-ecosystem"
    assert graphlaw["owner"] == "GraphLaw"
    assert universal["authority"] == "NONE"
    assert graphlaw["authority"] == "NONE"
  end
end

# --- SECTION 7: Original test/ash_a2a/durable_claim_store/durable_file_test.exs ---
defmodule AshA2A.DurableClaimStore.DurableFileTest do
  @moduledoc """
  Court for the durable `AshA2A.C2.ClaimStore` (`EffectClaimStore.DurableFile`).

  Chicago style: real filesystem under the build path (never tmp, so the
  durable-path guard is exercised for real), real concurrent processes and a
  real second BEAM (`elixir` subprocess) standing in for a restart. The
  verifier check `c1.durable_claim_store` is run against the real module.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: Store
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key :binary.copy(<<7>>, 32)

  setup do
    prev = Application.get_env(:ash_a2a, :claim_store_key)
    Application.put_env(:ash_a2a, :claim_store_key, @key)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_key, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_key)
    end)
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "claims_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(d)
    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "is durable and passes the verifier check" do
    assert Store.durable?()
    assert {:pass, _} = C1.durable_claim_store(%{claim_store: Store})
  end

  test "claim is compare-and-set: second claim of the same digest is refused" do
    d = dir()
    assert :ok = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 1, d)
    assert {:error, :already_claimed} = Store.claim("digest-a", 7, d)
    assert :ok = Store.claim("digest-b", 1, d)
  end

  test "complete records the result once; a completed claim stays claimed" do
    d = dir()
    assert {:error, :not_claimed} = Store.complete("nope", :r, d)
    :ok = Store.claim("c1", 1, d)
    assert :ok = Store.complete("c1", {:done, 1}, d)
    assert {:error, {:already_complete, {:done, 1}}} = Store.complete("c1", {:done, 2}, d)
    assert {:error, :already_claimed} = Store.claim("c1", 1, d)
    assert {:ok, %{state: :complete, result: {:done, 1}, generation: 1}} = Store.fetch("c1", d)
  end

  test "fence: a generation below the highest ever claimed is refused, atomically with the write" do
    d = dir()
    :ok = Store.claim("g5", 5, d)
    assert {:error, :stale_generation} = Store.claim("g3", 3, d)
    assert :not_found = Store.fetch("g3", d)
    assert :ok = Store.claim("g5b", 5, d)
    assert :ok = Store.claim("g9", 9, d)
    assert {:error, :stale_generation} = Store.claim("g5c", 5, d)
  end

  test "exactly one of many concurrent claimers wins" do
    d = dir()

    results =
      1..40
      |> Task.async_stream(fn _ -> Store.claim("race", 1, d) end,
        max_concurrency: 40,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_claimed})) == 39
  end

  test "survives a real BEAM restart in both directions" do
    d = dir()
    :ok = Store.claim("parent-claim", 2, d)

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile, as: S
      Application.put_env(:ash_a2a, :claim_store_key, #{inspect(@key)})
      dir = #{inspect(d)}
      IO.puts("parent:" <> inspect(S.claim("parent-claim", 2, dir)))
      IO.puts("child:" <> inspect(S.claim("child-claim", 2, dir)))
      IO.puts("stale:" <> inspect(S.claim("late", 1, dir)))
      """)

    assert out =~ "parent:{:error, :already_claimed}"
    assert out =~ "child::ok"
    assert out =~ "stale:{:error, :stale_generation}"
    assert {:error, :already_claimed} = Store.claim("child-claim", 2, d)
    assert {:ok, %{state: :claimed}} = Store.fetch("child-claim", d)
  end

  test "a tampered claim record is refused, never trusted" do
    d = dir()
    :ok = Store.claim("t", 1, d)
    [file] = Path.wildcard(Path.join([d, "claims", "*"]))
    bin = File.read!(file)
    File.write!(file, binary_part(bin, 0, byte_size(bin) - 1) <> <<0>>)
    assert {:error, :claim_record_corrupt} = Store.fetch("t", d)
    assert {:error, :claim_record_corrupt} = Store.claim("t", 1, d)
    assert {:error, :claim_record_corrupt} = Store.complete("t", :x, d)
  end

  test "a directory under tmp is refused (guard; anti-vacuity for the durable-path rule)" do
    tmp = Path.join(System.tmp_dir!(), "claims_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, tmp)
    refute File.exists?(tmp)
    assert {:error, :claim_store_dir_not_durable} = Store.claim("x", 1, nil)
  end

  test "the arity-2 ClaimStore callbacks read :claim_store_dir from app env" do
    d = dir()
    prev = Application.get_env(:ash_a2a, :claim_store_dir)
    Application.put_env(:ash_a2a, :claim_store_dir, d)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ash_a2a, :claim_store_dir, prev),
        else: Application.delete_env(:ash_a2a, :claim_store_dir)
    end)

    assert :ok = Store.claim("env-digest", 1)
    assert {:error, :already_claimed} = Store.claim("env-digest", 1)
    assert :ok = Store.complete("env-digest", :ok)
  end

  defp claim_file(d, digest),
    do: Path.join([d, "claims", Base.encode16(:crypto.hash(:sha256, digest), case: :lower)])

  test "D1: a record forged with a recomputed unkeyed SHA-256 is refused" do
    d = dir()
    :ok = Store.claim("f1", 1, d)
    path = claim_file(d, "f1")

    body =
      :erlang.term_to_binary(%{state: :complete, generation: 1, result: :forged}, [:deterministic])

    File.write!(path, [:crypto.hash(:sha256, body), body])
    assert {:error, :claim_record_corrupt} = Store.fetch("f1", d)
    assert {:error, :claim_record_corrupt} = Store.complete("f1", :x, d)
  end

  test "D1: a record forged under a different key is refused" do
    d = dir()
    :ok = Store.claim("f2", 1, d)
    path = claim_file(d, "f2")
    good = File.read!(path)
    Application.put_env(:ash_a2a, :claim_store_key, :binary.copy(<<9>>, 32))
    assert {:error, :claim_record_corrupt} = Store.fetch("f2", d)
    Application.put_env(:ash_a2a, :claim_store_key, @key)
    assert {:ok, %{state: :claimed}} = Store.fetch("f2", d)
    assert File.read!(path) == good
  end

  test "D1: a record copied onto another digest's path is refused" do
    d = dir()
    :ok = Store.claim("src", 1, d)
    :ok = Store.claim("dst", 1, d)
    :ok = Store.complete("src", :real, d)
    File.cp!(claim_file(d, "src"), claim_file(d, "dst"))
    assert {:error, :claim_record_corrupt} = Store.fetch("dst", d)
  end

  test "D1: no key configured refuses with claim_key_missing / claim_key_unavailable" do
    d = dir()
    Application.delete_env(:ash_a2a, :claim_store_key)
    Application.delete_env(:ash_a2a, :receipt_outbox_key)
    Application.delete_env(:ash_a2a, :receipt_binding_key)
    assert {:error, :claim_key_missing} = Store.claim("k", 1, d)
    Application.put_env(:ash_a2a, :claim_store_key, "short")
    assert {:error, :claim_key_unavailable} = Store.claim("k", 1, d)
  end

  test "D2: deleting a claim record does not re-open the claim" do
    d = dir()
    :ok = Store.claim("gone", 1, d)
    File.rm!(claim_file(d, "gone"))
    assert {:error, :claim_log_corrupt} = Store.claim("gone", 1, d)
    assert {:error, :claim_log_corrupt} = Store.fetch("gone", d)
  end

  test "D2: deleting the head/fence while claims exist is refused" do
    d = dir()
    :ok = Store.claim("h", 1, d)
    File.rm!(Path.join(d, "fence"))
    assert {:error, :claim_log_corrupt} = Store.claim("h2", 1, d)
  end

  test "D2: deleting a completed record is refused too" do
    d = dir()
    :ok = Store.claim("c", 1, d)
    :ok = Store.complete("c", :r, d)
    File.rm!(claim_file(d, "c"))
    assert {:error, :claim_log_corrupt} = Store.claim("c", 1, d)
  end

  test "D2: rolling a completed record back to its claimed state is refused" do
    d = dir()
    :ok = Store.claim("rb", 1, d)
    old = File.read!(claim_file(d, "rb"))
    :ok = Store.complete("rb", :r, d)
    File.write!(claim_file(d, "rb"), old)
    assert {:error, :claim_log_corrupt} = Store.complete("rb", :other, d)
  end
end

# --- SECTION 8: Original test/ash_a2a/durable_conformance/strict_c1_checks_test.exs ---
defmodule AshA2A.DurableConformance.StrictC1ChecksTest do
  @moduledoc """
  The verifier's `c1.security_profile_strict`, `c1.durable_claim_store` and
  `c1.keyed_journal` checks are PASSABLE by real configuration and still
  refuse weak configuration (anti-vacuity: each weakening flips its check).

  In-process: a real `:strict` profile module compiled from the real template,
  the real durable claim store, a real keyed journal directory and a real HMAC
  key custody provider. The full subprocess run under `MIX_ENV=conformance`
  is opt-in (`ASH_A2A_STRICT_CONFORMANCE_COURT=1`) because it compiles a whole
  build environment; see docs/reference/conformance-profiles.md.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.EffectClaimStore.DurableFile
  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.SA2A.Conformance.Checks.C1

  @key String.duplicate("s", 32)

  defmodule StrictProfile do
    use AshA2A.SecurityProfile.Template, env: :prod, requested: :strict
  end

  defmodule DevProfile do
    use AshA2A.SecurityProfile.Template, env: :test, requested: :dev_bypass
  end

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "conf_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp ctx(over \\ %{}) do
    Map.merge(
      %{
        security_profile_module: StrictProfile,
        claim_store: DurableFile,
        journal_dir: dir(),
        journal_key_provider: {HmacSha256, [key: @key]}
      },
      over
    )
  end

  test "all three checks pass under real strict configuration" do
    c = ctx()
    assert {:pass, _} = C1.security_profile_strict(c)
    assert {:pass, _} = C1.durable_claim_store(c)
    assert {:pass, _} = C1.keyed_journal(c)
  end

  test "the keyed journal check passes against a journal the real Journal module wrote" do
    d = dir()

    {:ok, h} =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.open(d, {HmacSha256, [key: @key]})

    :ok =
      AshA2A.ConsequenceKernel.PreparedEffectStore.Journal.put(h, %{
        digest: "x",
        bytes: "b",
        tag: "t",
        state: :prepared
      })

    assert {:pass, _} = C1.keyed_journal(ctx(%{journal_dir: d}))
  end

  test "anti-vacuity: weakening each input flips its check to fail" do
    assert {:fail, _} = C1.security_profile_strict(ctx(%{security_profile_module: DevProfile}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.MemoryClaimStore}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: AshA2A.C2.ClaimStoreETS}))
    assert {:fail, _} = C1.durable_claim_store(ctx(%{claim_store: nil}))
    tmp = Path.join(System.tmp_dir!(), "j_#{System.unique_integer([:positive])}")
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_dir: tmp}))
    assert {:fail, _} = C1.keyed_journal(ctx(%{journal_key_provider: nil}))

    assert {:fail, _} =
             C1.keyed_journal(ctx(%{journal_key_provider: {HmacSha256, [key: "short"]}}))
  end

  test "the profile cannot be selected by task options or request data" do
    # current/0 takes no arguments and the check reads only the compiled module.
    refute function_exported?(StrictProfile, :current, 1)

    assert {:fail, _} =
             C1.security_profile_strict(
               ctx(%{security_profile_module: DevProfile, profile: :strict})
             )
  end

  @tag skip:
         System.get_env("ASH_A2A_STRICT_CONFORMANCE_COURT") != "1" &&
           "opt-in: set ASH_A2A_STRICT_CONFORMANCE_COURT=1 (compiles the conformance build env)"
  test "MIX_ENV=conformance mix ash_a2a.verify_conformance --profile c1 passes the three checks" do
    data = dir()
    File.mkdir_p!(data)

    {out, _status} =
      System.cmd("mix", ["ash_a2a.verify_conformance", "--profile", "c1", "--report"],
        env: [
          {"MIX_ENV", "conformance"},
          {"ASH_A2A_DATA_DIR", data},
          {"ASH_A2A_OUTBOX_KEY_B64", Base.encode64(@key)}
        ],
        stderr_to_stdout: true
      )

    for id <- ~w(c1.security_profile_strict c1.durable_claim_store c1.keyed_journal) do
      assert out =~ ~r/PASS\s+#{Regex.escape(id)}/, "#{id} did not PASS:\n#{out}"
    end
  end
end

# --- SECTION 9: Original test/ash_a2a/durable_prepared_journal/journal_test.exs ---
defmodule AshA2A.DurablePreparedJournal.JournalTest do
  @moduledoc """
  Court for the keyed, sequence-numbered `PreparedEffectStore.Journal`.

  Real files under the build path (non-tmp), real HMAC key custody, real
  second BEAM for the restart case. Tampering is done by editing the real
  journal bytes; the oracle is the refusal code, not a call count.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal

  @key String.duplicate("k", 32)

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "journal_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp open!(d, key \\ @key) do
    {:ok, h} = Journal.open(d, {HmacSha256, [key: key]})
    h
  end

  defp record(digest),
    do: %{digest: digest, bytes: "bytes-" <> digest, tag: "t", state: :prepared}

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "put/fetch/transition/claim/complete follow the store contract" do
    h = open!(dir())
    assert :ok = Journal.put(h, record("d1"))
    assert {:error, :prepared_duplicate} = Journal.put(h, record("d1"))
    assert {:ok, %{digest: "d1", state: :prepared}} = Journal.fetch(h, "d1")
    assert :not_found = Journal.fetch(h, "zz")

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :completed)

    assert :ok = Journal.transition(h, "d1", :prepared, :claimed)

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :claimed)

    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_request(h, "r1", :owner_b)
    assert :ok = Journal.claim_effect(h, "e1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_effect(h, "e1", :owner_b)
    assert {:error, :prepared_not_completed} = Journal.complete(h, "d1", :out)
    :ok = Journal.transition(h, "d1", :claimed, :applying)
    :ok = Journal.transition(h, "d1", :applying, :completed)
    assert :ok = Journal.complete(h, "d1", :out)
    assert {:ok, %{state: :completed, outcome: :out}} = Journal.fetch(h, "d1")
  end

  test "entries are sequence-numbered 1..n without gaps" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    :ok = Journal.transition(h, "a", :prepared, :claimed)
    assert {:ok, [1, 2, 3]} = Journal.sequence(h)
    assert {:ok, 3} = Journal.head(h)
  end

  test "PreparedEffectStore.prepare/3 seals a real PreparedEffect into the journal and is idempotent" do
    d = dir()
    h = open!(d)

    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{"n" => System.unique_integer([:positive])},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    opts = [key_provider: HmacSha256, key_opts: [key: @key]]

    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert {:ok, %{digest: digest}} = Journal.fetch(open!(d), p.prepared_digest)
    assert digest == p.prepared_digest
    assert {:ok, 1} = Journal.head(h)

    assert {:error, :claim_conflict} =
             PreparedEffectStore.claim_request({Journal, h}, "rq", :o)
             |> then(fn :ok -> PreparedEffectStore.claim_request({Journal, h}, "rq", :p) end)
  end

  test "state survives a real BEAM restart; the second BEAM continues the sequence" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("r1"))

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal
      {:ok, h} = Journal.open(#{inspect(d)}, {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: #{inspect(@key)}]})
      IO.puts("dup:" <> inspect(Journal.put(h, %{digest: "r1", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("put:" <> inspect(Journal.put(h, %{digest: "r2", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("seq:" <> inspect(Journal.sequence(h)))
      """)

    assert out =~ "dup:{:error, :prepared_duplicate}"
    assert out =~ "put::ok"
    assert out =~ "seq:{:ok, [1, 2]}"
    assert {:ok, %{digest: "r2"}} = Journal.fetch(h, "r2")
  end

  test "opening with a different key is refused (authentication, not silence)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("k1"))
    h2 = open!(d, String.duplicate("z", 32))
    assert {:error, :prepared_authentication_failed} = Journal.fetch(h2, "k1")
    assert {:error, :prepared_authentication_failed} = Journal.put(h2, record("k2"))
  end

  test "a flipped byte in the journal is refused" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("t1"))
    :ok = Journal.put(h, record("t2"))
    log = Path.join(d, "journal.log")
    bin = File.read!(log)
    pos = div(byte_size(bin), 2)
    <<pre::binary-size(^pos), b, post::binary>> = bin
    File.write!(log, <<pre::binary, Bitwise.bxor(b, 1), post::binary>>)
    assert {:error, e} = Journal.fetch(h, "t1")
    assert e in [:prepared_authentication_failed, :journal_corrupt]
  end

  test "a truncated journal (dropped tail entry) is refused against the MAC'd head" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    size1 = File.stat!(Path.join(d, "journal.log")).size
    :ok = Journal.put(h, record("b"))

    File.write!(
      Path.join(d, "journal.log"),
      binary_part(File.read!(Path.join(d, "journal.log")), 0, size1)
    )

    assert {:error, :journal_truncated} = Journal.fetch(h, "a")
  end

  test "a swapped/reordered entry is refused (chain)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    log = Path.join(d, "journal.log")
    File.write!(log, File.read!(log) <> File.read!(log))
    assert {:error, e} = Journal.fetch(h, "a")
    assert e in [:prepared_authentication_failed, :journal_corrupt, :journal_sequence_gap]
  end

  test "an entry spliced in from another journal under the same key is refused (chain)" do
    frames = fn d ->
      bin = File.read!(Path.join(d, "journal.log"))
      <<l1::32, _::binary-size(l1), t1::16, _::binary-size(t1), _::binary>> = bin
      first = 4 + l1 + 2 + t1
      {binary_part(bin, 0, first), binary_part(bin, first, byte_size(bin) - first)}
    end

    da = dir()
    ha = open!(da)
    :ok = Journal.put(ha, record("a1"))
    :ok = Journal.put(ha, record("a2"))
    db = dir()
    hb = open!(db)
    :ok = Journal.put(hb, record("b1"))
    :ok = Journal.put(hb, record("b2"))
    {a_first, _} = frames.(da)
    {_, b_second} = frames.(db)
    File.write!(Path.join(da, "journal.log"), a_first <> b_second)
    assert {:error, :prepared_authentication_failed} = Journal.fetch(ha, "a1")
  end

  test "mandatory key: no key, short key, and no provider are refused at open" do
    d = dir()
    assert {:error, :journal_key_missing} = Journal.open(d, nil)
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, [key: "short"]})
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, []})
  end

  test "a tmp directory is refused at open" do
    tmp = Path.join(System.tmp_dir!(), "journal_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :journal_dir_not_durable} = Journal.open(tmp, {HmacSha256, [key: @key]})
    assert {:error, :journal_dir_not_durable} = Journal.open(nil, {HmacSha256, [key: @key]})
    refute File.exists?(tmp)
  end

  test "from_config/0 builds the handle from real app env" do
    d = dir()
    keys = [:receipt_outbox_dir, :receipt_outbox_key, :prepared_journal_dir]
    prev = for k <- keys, do: {k, Application.get_env(:ash_a2a, k)}
    Application.put_env(:ash_a2a, :receipt_outbox_dir, d)
    Application.put_env(:ash_a2a, :receipt_outbox_key, @key)
    Application.delete_env(:ash_a2a, :prepared_journal_dir)

    on_exit(fn ->
      for {k, v} <- prev,
          do:
            if(v == nil,
              do: Application.delete_env(:ash_a2a, k),
              else: Application.put_env(:ash_a2a, k, v)
            )
    end)

    assert {:ok, h} = Journal.from_config()
    assert :ok = Journal.put(h, record("cfg"))
    assert File.exists?(Path.join([d, "prepared_journal", "journal.log"]))
  end
end

# --- SECTION 10: Original test/ash_a2a/evidence/affidavit_test.exs ---
defmodule AshA2A.Evidence.AffidavitTest do
  use ExUnit.Case, async: true

  alias AshA2A.Evidence.Affidavit

  setup do
    if Affidavit.available?() and is_nil(Process.whereis(AshAffidavit.Pool)) do
      start_supervised!({AshAffidavit.Pool, size: 2})
    end

    :ok
  end

  describe "AshA2A.Evidence.Affidavit" do
    test "available?/0 returns true when ash_affidavit is loaded" do
      assert Affidavit.available?() == true
    end

    test "assemble_receipt/1 and verify_receipt/1 execute with real WASM engine" do
      events = [
        %{"event_type" => "start", "objects" => ["task:1"], "payload" => "init"},
        %{"event_type" => "finish", "objects" => ["task:1"], "payload" => "done"}
      ]

      assert {:ok, assembled} = Affidavit.assemble_receipt(events)
      assert is_map(assembled)
      assert Map.has_key?(assembled, "receipt")

      assert {:ok, true} = Affidavit.verify_receipt(assembled["receipt"])
    end
  end
end

# --- SECTION 11: Original test/ash_a2a/graph_law/subprocess_test.exs ---
defmodule AshA2A.GraphLaw.SubprocessTest do
  @moduledoc """
  Chicago-school court for `AshA2A.GraphLaw.Subprocess` (PERF-03, PERF-12):
  real OS processes (`sh`, `sleep`, `kill -0`), no doubles. `async: false`
  because the concurrency cap is a node-wide counter.
  """

  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.Subprocess

  test "a completed process returns stdout and its exit status; stderr is not merged" do
    assert {:ok, {"out\n", 3}} =
             Subprocess.run("sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout_ms: 5_000)
  end

  test "a hung process is killed at the deadline and typed :graphlaw_host_timeout" do
    started = System.monotonic_time(:millisecond)

    assert {:error, %{code: :graphlaw_host_timeout, os_pid: os_pid}} =
             Subprocess.run("sleep", ["30"], timeout_ms: 200)

    assert System.monotonic_time(:millisecond) - started < 5_000
    # The OS process is really gone, not merely abandoned.
    AshA2A.TestSupport.Eventually.eventually(
      fn ->
        {_, status} =
          System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

        status != 0
      end,
      message: "OS process #{os_pid} still alive"
    )

    assert Subprocess.in_flight() == 0
    refute_received {_port, {:exit_status, _}}
  end

  test "a spawn over the concurrency cap is shed, not queued" do
    parent = self()

    holder =
      Task.async(fn ->
        send(parent, :holding)
        Subprocess.run("sleep", ["2"], timeout_ms: 5_000, max_concurrency: 1)
      end)

    assert_receive :holding
    wait_until(fn -> Subprocess.in_flight() >= 1 end)

    assert {:error, %{code: :graphlaw_host_saturated, max_concurrency: 1}} =
             Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)

    assert {:ok, {"", 0}} = Task.await(holder, 10_000)
    assert Subprocess.in_flight() == 0
    assert {:ok, {"x\n", 0}} = Subprocess.run("sh", ["-c", "echo x"], max_concurrency: 1)
  end

  test "run/3 returns only after its slot is released: back-to-back runs at cap 1 are never shed" do
    # The slot used to be released by a watcher process asynchronously, so `run/3`
    # could return while `in_flight/0` was still 1 and an immediate re-run at the
    # cap was spuriously shed (`:graphlaw_host_saturated`).
    results =
      for _ <- 1..300 do
        {Subprocess.run("true", [], max_concurrency: 1), Subprocess.in_flight()}
      end

    assert Enum.all?(results, fn {run, in_flight} ->
             match?({:ok, {"", 0}}, run) and in_flight == 0
           end),
           "a run was shed or returned before releasing its slot: " <>
             inspect(
               Enum.find(results, fn {run, n} -> not match?({:ok, {"", 0}}, run) or n != 0 end)
             )
  end

  test "a caller killed mid-run releases its slot and its OS process" do
    marker = "31.#{System.unique_integer([:positive])}"
    task = Task.async(fn -> Subprocess.run("sleep", [marker], timeout_ms: 60_000) end)

    wait_until(fn -> Subprocess.in_flight() >= 1 end)
    wait_until(fn -> match?({_, 0}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
    assert Task.shutdown(task, :brutal_kill) == nil

    wait_until(fn -> Subprocess.in_flight() == 0 end)
    wait_until(fn -> match?({_, 1}, System.cmd("pgrep", ["-f", "sleep #{marker}"])) end)
  end

  test "a missing executable is a typed spawn failure" do
    assert {:error, %{code: :graphlaw_host_spawn_failed}} =
             Subprocess.run("definitely-not-an-executable-xyz", [])
  end

  test "the peer transport's availability probe spawns node at most once per artifact" do
    if System.find_executable("node") do
      assert AshA2A.Semantic.GraphLaw.Wasm.available?()
      {us, true} = :timer.tc(&AshA2A.Semantic.GraphLaw.Wasm.available?/0)
      # A node spawn + 3.2 MB instantiation measured ~100 ms; a memo hit is
      # two stat calls and a persistent_term read.
      assert us < 10_000, "memoized available?/0 took #{us} us"
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      true -> AshA2A.TestSupport.Eventually.pause(10) && wait_until(fun, tries - 1)
    end
  end
end

# --- SECTION 12: Original test/ash_a2a/graph_law/unpinned_refusal_test.exs ---
defmodule AshA2A.GraphLaw.UnpinnedRefusalTest do
  use ExUnit.Case, async: false

  alias AshA2A.GraphLaw.EngineLoad

  setup do
    prev = Application.fetch_env(:ash_a2a, :graphlaw_allow_unpinned)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, v)
        :error -> Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)
      end
    end)

    :ok
  end

  test ":unpinned is refused by default (runtime config)" do
    Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)

    assert {:error, %{code: :graphlaw_wasm_unpinned_refused}} =
             EngineLoad.check_digest("abc", :unpinned)
  end

  test ":unpinned is admitted only when explicitly enabled" do
    Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, true)
    assert :ok = EngineLoad.check_digest("abc", :unpinned)
  end

  test "resolve_wasm_path refuses a missing path with a typed error" do
    path = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer([:positive])}.wasm")

    assert {:error, %{code: :graphlaw_wasm_missing}} =
             AshA2A.GraphLaw.resolve_wasm_path(wasm_path: path)
  end
end

# --- SECTION 13: Original test/ash_a2a/graph_law/wasmex_host_hardening_test.exs ---
defmodule AshA2A.GraphLaw.WasmexHostHardeningTest do
  @moduledoc """
  Chicago-school courts for the production hardening of the in-BEAM GraphLaw
  host (SC-04, PERF-02, PERF-04, PERF-05, PERF-06, PERF-07, PERF-08).

  Every assertion runs the REAL vendored `praxis_graphlaw.wasm` in REAL
  Wasmtime instances; substituted artifacts are real bytes written to a real
  tmp dir. Nothing is mocked. `async: false` because some cases change
  application env (`:graphlaw_max_queue`) or count engine telemetry events.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :tmp_dir

  alias AshA2A.GraphLaw.{EngineLoad, EngineTelemetry, WasmexHost, WasmexPool, WasmexSession}
  alias AshA2A.Semantic.{CanonicalDigest, GraphLaw, GraphLawBridge}

  @base_ttl "@prefix ex: <http://example.org/> .\nex:a ex:p ex:b .\nex:b ex:p ex:c .\n"
  @base_digest "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"

  # `:unpinned` (a caller-named foreign path, or the explicit opt-out) is
  # admitted only under runtime opt-in; the default-refusal law is pinned in
  # unpinned_refusal_test.exs. Digest-pinned cases below are unaffected.
  setup do
    previous = Application.fetch_env(:ash_a2a, :graphlaw_allow_unpinned)
    Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, true)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:ash_a2a, :graphlaw_allow_unpinned, v)
        :error -> Application.delete_env(:ash_a2a, :graphlaw_allow_unpinned)
      end
    end)

    :ok
  end

  defp vendored, do: AshA2A.GraphLaw.wasm_path()

  # A valid wasm module with the same code and imports as the pinned artifact,
  # but different bytes: one appended custom section (id 0, name "x",
  # payload "y"). Custom sections are ignored by the engine, so only the
  # digest pin can tell the two apart.
  defp substituted_wasm!(dir) do
    path = Path.join(dir, "substituted.wasm")
    File.write!(path, File.read!(vendored()) <> <<0, 3, 1, ?x, ?y>>)
    path
  end

  defp unique_name(tag),
    do: Module.concat(__MODULE__, "#{tag}#{System.unique_integer([:positive])}")

  defp start_host(opts) do
    name = unique_name("Host")
    pid = start_supervised!({WasmexHost, [name: name] ++ opts}, id: name)
    {name, pid}
  end

  defp big_ttl(n) do
    body = Enum.map_join(1..n, "\n", fn i -> "ex:s#{i} ex:p ex:o#{i + 1} ." end)
    "@prefix ex: <http://example.org/> .\n" <> body <> "\n"
  end

  describe "SC-04 digest pin" do
    test "a substituted artifact is refused by the pinned host, loads only when unpinned",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      pinned = EngineLoad.pinned_sha256()

      {name, _pid} = start_host(wasm_path: path)

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch, expected: ^pinned, actual: actual}} =
               GenServer.call(name, :status)

      assert actual != pinned

      assert WasmexHost.graph_hash(@base_ttl, name) |> elem(1) |> Map.get(:code) ==
               :graphlaw_wasm_digest_mismatch

      {open, _} = start_host(wasm_path: path, expected_sha256: :unpinned)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, open)
    end

    test "the vendored artifact matches the MANIFEST pin and the pin is classified" do
      bytes = File.read!(vendored())

      assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
               EngineLoad.pinned_sha256()

      assert {:ok, %{wasm_sha256: sha}} = EngineLoad.load("test", bytes)
      assert sha == EngineLoad.pinned_sha256()

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
               EngineLoad.load("test", bytes <> <<0, 3, 1, ?x, ?y>>)

      assert AshA2A.Semantic.Refusal.classify(:graphlaw_wasm_digest_mismatch) ==
               :refused_identity
    end

    test "a session on the vendored path is pinned; a named foreign path is the caller's choice",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)

      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
               WasmexSession.open(wasm_path: path, expected_sha256: EngineLoad.pinned_sha256())

      assert {:ok, %{session: session}} = WasmexSession.open(wasm_path: path)
      WasmexSession.close(session)
    end

    test "the peer (node) transport is pinned too, so a refused host cannot fall back to swapped bytes",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      peer = AshA2A.Semantic.GraphLaw.Wasm
      previous = Application.get_env(:ash_a2a, peer)

      # Not named by the operator (an ambient GRAPHLAW_WASM, or the vendored
      # file itself swapped): held to the MANIFEST pin.
      assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} = peer.check_pin(path)
      assert :ok = peer.check_pin(vendored())

      # The call path itself consults the pin (this module is async: false and
      # restores any value the developer had set).
      previous_env = System.get_env("PRAXIS_GRAPHLAW_WASM")

      if is_binary(System.find_executable("node")) and is_nil((previous || [])[:wasm_path]) do
        try do
          System.put_env("PRAXIS_GRAPHLAW_WASM", path)

          assert {:error, %{code: :graphlaw_wasm_digest_mismatch}} =
                   peer.graph_hash(@base_ttl)
        after
          if previous_env,
            do: System.put_env("PRAXIS_GRAPHLAW_WASM", previous_env),
            else: System.delete_env("PRAXIS_GRAPHLAW_WASM")
        end
      end

      try do
        # Named explicitly by the operator: the operator's choice of bytes.
        Application.put_env(:ash_a2a, peer, Keyword.put(previous || [], :wasm_path, path))
        assert :ok = peer.check_pin(path)

        if System.find_executable("node") do
          assert {:ok, @base_digest} = peer.graph_hash(@base_ttl)
        end
      after
        if previous,
          do: Application.put_env(:ash_a2a, peer, previous),
          else: Application.delete_env(:ash_a2a, peer)
      end

      assert AshA2A.Semantic.Refusal.classify(:graphlaw_wasm_digest_mismatch) == :refused_identity
    end

    test "a session path that arrived through configuration is pinned, not the caller's choice",
         %{tmp_dir: dir} do
      path = substituted_wasm!(dir)
      previous_path = Application.get_env(:ash_a2a, :graphlaw_wasm_path)
      previous_sha = Application.get_env(:ash_a2a, :graphlaw_wasm_sha256)

      restore = fn key, previous ->
        if previous,
          do: Application.put_env(:ash_a2a, key, previous),
          else: Application.delete_env(:ash_a2a, key)
      end

      try do
        Application.put_env(:ash_a2a, :graphlaw_wasm_path, path)
        Application.delete_env(:ash_a2a, :graphlaw_wasm_sha256)

        assert {:error, %{code: :graphlaw_wasm_digest_mismatch, path: ^path}} =
                 WasmexSession.open([])

        # The operator's explicit opt-out for a configured rebuild.
        Application.put_env(:ash_a2a, :graphlaw_wasm_sha256, :unpinned)
        assert {:ok, %{session: session}} = WasmexSession.open([])
        WasmexSession.close(session)
      after
        restore.(:graphlaw_wasm_path, previous_path)
        restore.(:graphlaw_wasm_sha256, previous_sha)
      end
    end
  end

  describe "PERF-02 compiled-module cache" do
    test "a warm open costs an instantiation, not a compile; sessions stay isolated" do
      {:ok, %{session: warm}} = WasmexSession.open(fuel: 1_000_000_000)
      WasmexSession.close(warm)
      assert EngineLoad.cached?(EngineLoad.pinned_sha256(), true)

      timings =
        for _ <- 1..3 do
          {us, {:ok, %{session: s}}} =
            :timer.tc(fn -> WasmexSession.open(fuel: 1_000_000_000) end)

          WasmexSession.close(s)
          us
        end

      # A Cranelift compile of this module measured 1.04-1.22 s per open.
      assert Enum.max(timings) < 300_000, "warm opens took #{inspect(timings)} us"

      {:ok, %{session: a}} = WasmexSession.open(fuel: 5_000_000_000)
      {:ok, %{session: b}} = WasmexSession.open(fuel: 5_000_000_000)

      try do
        assert a.store != b.store and a.pid != b.pid
        fuel_a = WasmexSession.fuel_remaining(a)
        fuel_b = WasmexSession.fuel_remaining(b)
        assert {:ok, @base_digest} = WasmexSession.call(a, :graph_hash, [@base_ttl])
        # Only a's own store paid for a's call.
        assert WasmexSession.fuel_remaining(a) < fuel_a
        assert WasmexSession.fuel_remaining(b) == fuel_b
      after
        WasmexSession.close(a)
        WasmexSession.close(b)
      end
    end
  end

  describe "PERF-04 a timed-out call never kills the host" do
    test "native interrupt returns a typed error, the host recycles in-process and keeps serving" do
      {name, pid} = start_host([])
      ref = Process.monitor(pid)
      ttl = big_ttl(3_000)

      assert {:error, %{code: code}} = WasmexHost.validate_all(ttl, "", "", "", "", name, 1)
      assert code in [:graphlaw_call_failed, :graphlaw_call_exited]
      refute_received {:DOWN, ^ref, _, _, _}
      assert Process.alive?(pid)

      assert {:ok, %{recycles: recycles}} = WasmexHost.info(name)
      assert recycles >= 1
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
    end
  end

  describe "PERF-05 fuel and memory bounds" do
    test "a call that exhausts the per-transaction fuel budget is a typed error, not a hang" do
      {name, pid} = start_host(fuel: 10_000)
      assert {:error, %{code: :graphlaw_call_failed}} = WasmexHost.graph_hash(@base_ttl, name)
      assert Process.alive?(pid)
    end

    test "fuel is reset per transaction, so a sufficient budget serves repeated calls" do
      {name, _pid} = start_host(fuel: 2_000_000_000)

      for _ <- 1..5 do
        assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      end
    end

    test "crossing the memory high-water mark recycles the instance" do
      {name, _pid} = start_host(recycle_bytes: 1)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      assert {:ok, %{recycles: 1}} = WasmexHost.info(name)
      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
      assert {:ok, %{recycles: 2}} = WasmexHost.info(name)
    end
  end

  describe "PERF-06 pool and load shedding" do
    test "a pool runs N independent hosts over one compiled module" do
      registry = unique_name("Registry")
      sup = unique_name("Pool")

      start_supervised!(
        {WasmexPool, name: sup, registry: registry, size: 3, host_name: nil},
        id: sup
      )

      members = WasmexPool.members(registry)
      assert length(Enum.uniq(members)) == 3
      assert WasmexPool.pick(registry) in members

      results =
        members
        |> Enum.flat_map(&List.duplicate(&1, 4))
        |> Task.async_stream(&WasmexHost.graph_hash(@base_ttl, &1), max_concurrency: 12)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.uniq(results) == [{:ok, @base_digest}]
    end

    test "a restarted registry gets every member back" do
      registry = unique_name("Registry")
      sup = unique_name("Pool")

      start_supervised!(
        {WasmexPool, name: sup, registry: registry, size: 3, host_name: nil},
        id: sup
      )

      assert length(WasmexPool.members(registry)) == 3
      old = Process.whereis(registry)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000

      members =
        Enum.reduce_while(1..100, [], fn _, _ ->
          case WasmexPool.members(registry) do
            list when length(list) == 3 ->
              {:halt, list}

            list ->
              Process.sleep(50)
              {:cont, list}
          end
        end)

      assert length(members) == 3,
             "after a registry restart only #{length(members)} of 3 members are routable"

      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, WasmexPool.pick(registry))
    end

    test "a target at the queue bound is shed with :graphlaw_saturated" do
      {name, _pid} = start_host([])
      previous = Application.get_env(:ash_a2a, :graphlaw_max_queue)
      Application.put_env(:ash_a2a, :graphlaw_max_queue, 0)

      try do
        assert {:error, %{code: :graphlaw_saturated, max_queue: 0}} =
                 WasmexHost.graph_hash(@base_ttl, name)
      after
        if previous,
          do: Application.put_env(:ash_a2a, :graphlaw_max_queue, previous),
          else: Application.delete_env(:ash_a2a, :graphlaw_max_queue)
      end

      assert {:ok, @base_digest} = WasmexHost.graph_hash(@base_ttl, name)
    end
  end

  describe "PERF-01/07/08 admission path on the warm host" do
    test "the default semantic engine is the in-BEAM host and agrees with the node runtime" do
      assert GraphLaw.impl() == AshA2A.Semantic.GraphLaw.WasmexHost
      assert GraphLawBridge.host() == :in_beam

      {us, {:ok, beam}} = :timer.tc(fn -> GraphLaw.graph_hash(@base_ttl) end)
      assert beam == @base_digest
      assert us < 50_000, "in-BEAM graph_hash took #{us} us"

      if AshA2A.Semantic.GraphLaw.Wasm.available?() do
        assert {:ok, ^beam} = AshA2A.Semantic.GraphLaw.Wasm.graph_hash(@base_ttl)
      end
    end

    test "validate_all's report graph_hash equals graph_hash over the conformance corpus" do
      {:ok, doc} = AshA2A.GraphLaw.ConformanceVectors.load()

      corpus =
        (doc["vectors"]
         |> Enum.filter(&(&1["fn"] in ["graph_hash", "validate_all"]))
         |> Enum.map(&hd(&1["args"]))) ++
          Enum.map(Path.wildcard("priv/graphlaw/fixtures/*.ttl"), &File.read!/1) ++
          [@base_ttl, big_ttl(50)]

      assert length(corpus) >= 5

      for ttl <- Enum.uniq(corpus) do
        {:ok, hash} = GraphLaw.graph_hash(ttl)
        {:ok, report} = GraphLaw.validate(ttl, "")
        assert report["graph_hash"] == hash
      end
    end

    test "validate_many returns the same reports as per-pair validate, in order" do
      shapes = """
      @prefix sh: <http://www.w3.org/ns/shacl#> .
      @prefix ex: <http://example.org/> .
      ex:S a sh:NodeShape ; sh:targetSubjectsOf ex:p ; sh:property [ sh:path ex:q ; sh:minCount 1 ] .
      """

      pairs = [{@base_ttl, ""}, {@base_ttl, shapes}, {big_ttl(5), ""}]
      assert {:ok, many} = GraphLaw.validate_many(pairs)

      singles =
        Enum.map(pairs, fn {t, s} ->
          {:ok, r} = GraphLaw.validate(t, s)
          r
        end)

      strip = fn r -> Map.drop(r, ["timing", "elapsed_us"]) end
      assert Enum.map(many, strip) == Enum.map(singles, strip)
      assert Enum.map(many, &GraphLaw.verdict/1) |> Enum.at(1) |> elem(0) == :refused
    end

    test "canonical digest spends one engine call for :ntriples and two for :turtle" do
      triples = [
        %{
          subject: "http://example.org/a",
          predicate: "http://example.org/p",
          object: {:iri, "http://example.org/b"}
        }
      ]

      {:ok, _} = CanonicalDigest.canonical_digest(triples)
      {:ok, _} = CanonicalDigest.canonical_digest(triples, format: :turtle)

      count = fn fun ->
        parent = self()
        handler = "perf08-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          EngineTelemetry.event(),
          fn _e, _m, meta, _ -> if meta.host == "BEAM/WasmexHost", do: send(parent, :call) end,
          nil
        )

        try do
          {:ok, digest} = fun.()
          {digest, drain(0)}
        after
          :telemetry.detach(handler)
        end
      end

      {nt, nt_calls} = count.(fn -> CanonicalDigest.canonical_digest(triples) end)

      {tt, tt_calls} =
        count.(fn -> CanonicalDigest.canonical_digest(triples, format: :turtle) end)

      assert nt_calls == 1
      assert tt_calls == 2
      assert nt.digest == tt.digest
    end
  end

  defp drain(n) do
    receive do
      :call -> drain(n + 1)
    after
      50 -> n
    end
  end
end

# --- SECTION 14: Original test/ash_a2a/graph_law/wasmtime_runtime_test.exs ---
defmodule AshA2A.GraphLaw.WasmtimeRuntimeTest do
  @moduledoc """
  Real, non-mocked exercise of `AshA2A.GraphLaw.WasmtimeRuntime`, the native
  Wasmtime host: every assertion below is on a value that came back from a
  real OS subprocess (`native/graphlaw_host`) that really compiled and ran
  `priv/graphlaw/praxis_graphlaw.wasm` under Wasmtime.

  There is no test double anywhere in this file. No wasm result is
  hand-constructed, no collaborator is stubbed, and nothing asserts "was X
  called" -- the assertions are on real returned digests, real JSON, and real
  typed errors.

  The expected digests are not this test's invention either: they are the
  values the same artifact produces under a *different* host (a hand-written
  JavaScript shim over `WebAssembly.instantiate` in Node), recorded as the
  conformance vectors for RFC-SA2A-001 S12/S51. That is the whole experiment:
  same bytes, different host, same answers.

  When `native/graphlaw_host/target/release/graphlaw_host` has not been built
  the wasm-executing tests are **skipped by name and loudly**, never silently
  replaced by a double. Build it with:

      cd native/graphlaw_host && cargo build --release
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  alias AshA2A.GraphLaw.ConformanceVectors
  alias AshA2A.GraphLaw.{Runtime, RuntimeB, WasmexSession, WasmtimeRuntime}

  # --- Conformance vectors (RFC-SA2A-001 S12 canonical graph identity) -------

  @base """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:c .
  """

  # Same graph, different prefix *label* and different triple *order*.
  # A canonicalizing hash must not be able to tell it apart from @base.
  @reordered """
  @prefix zz: <http://example.org/> .
  zz:b zz:p zz:c .
  zz:a zz:p zz:b .
  """

  # One object term changed: must hash differently.
  @different """
  @prefix ex: <http://example.org/> .
  ex:a ex:p ex:b .
  ex:b ex:p ex:ZZZ .
  """

  @base_hash "9b8180962a93910d17c51d029626f393d65ac2f724b9ffc657c90bc4f3b5939d"
  @different_hash "610ccbcd4ed4b23cf4179fde360625da286557d18a15403f76797e28c1c68f66"

  # The published BLAKE3 test vector for the input "abc".
  @blake3_abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

  # The published BLAKE3 test vector for the *empty* input, which is also what
  # an empty graph's canonical N-Quads form hashes to.
  @empty_graph_hash "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

  @vendored_wasm_sha256 "187688d9e7e33a575713d6911d75687adb38713ed37412e211af263dfcbe0c28"

  @junk_inputs ["this is not turtle <<<", "@@@ bad", "<http://a> <http://b"]

  # The pure digest/parse tests below all read from ONE real native-host batch
  # (one subprocess, one wasm compile) instead of one spawn (~1.4s) per call.
  # Every job is a real wasm call in the real host; only the spawn is shared.
  # Tests that assert process isolation, timeout, artifact identity or error
  # paths keep their own fresh spawns.
  setup_all do
    if WasmtimeRuntime.available?() == :ok do
      keyed_jobs =
        [
          {:base, {"graph_hash", [@base]}},
          {:reordered, {"graph_hash", [@reordered]}},
          {:different, {"graph_hash", [@different]}},
          {:blake3_abc, {"blake3_hex", ["abc"]}},
          {:empty_graph, {"graph_hash", [""]}},
          {:blake3_empty, {"blake3_hex", [""]}}
        ] ++
          Enum.map(@junk_inputs, &{{:junk, &1}, {"graph_hash", [&1]}})

      {:ok, %{results: results}} = WasmtimeRuntime.batch(Enum.map(keyed_jobs, &elem(&1, 1)))
      %{pure: keyed_jobs |> Enum.map(&elem(&1, 0)) |> Enum.zip(results) |> Map.new()}
    else
      %{pure: %{}}
    end
  end

  describe "path resolution and availability (no subprocess)" do
    test "wasm_digest/1 hashes the real vendored artifact on disk" do
      assert {:ok, @vendored_wasm_sha256} = WasmtimeRuntime.wasm_digest()
    end

    test "a missing native binary is a typed refusal, not a crash" do
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base, binary_path: "/nonexistent/graphlaw_host")

      assert error.code == :graphlaw_host_not_built
      assert error.path == "/nonexistent/graphlaw_host"
      assert error.message =~ "cargo build --release"
    end

    test "a missing wasm artifact is a typed refusal, not a crash" do
      # `/bin/sh` really exists, so the binary check passes and the wasm check
      # is the one that fires -- and no subprocess is ever spawned, because the
      # refusal happens before that.
      assert {:error, error} =
               WasmtimeRuntime.graph_hash(@base,
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )

      assert error.code == :graphlaw_wasm_missing
    end

    test "available?/1 reports real on-disk state as the Runtime behaviour shape" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.available?(binary_path: "/nonexistent/graphlaw_host")

      assert {:error, %{code: :graphlaw_wasm_missing}} =
               WasmtimeRuntime.available?(
                 binary_path: "/bin/sh",
                 wasm_path: "/nonexistent/graphlaw.wasm"
               )
    end
  end

  describe "AshA2A.GraphLaw.Runtime identity (no subprocess)" do
    test "declares the Runtime behaviour" do
      behaviours = WasmtimeRuntime.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Runtime in List.flatten(behaviours)
    end

    test "is a distinct {host_id, engine_id} from both court default runtimes" do
      assert Runtime.identity(WasmtimeRuntime) == {"Native/graphlaw_host", "wasmtime"}
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(WasmexSession)
      assert Runtime.identity(WasmtimeRuntime) != Runtime.identity(RuntimeB)
    end

    test "open/1 over an unbuilt host is the typed refusal, not a session" do
      assert {:error, %{code: :graphlaw_host_not_built}} =
               WasmtimeRuntime.open(binary_path: "/nonexistent/graphlaw_host")
    end
  end

  if AshA2A.GraphLaw.WasmtimeRuntime.available?() == :ok do
    describe "AshA2A.GraphLaw.Runtime callbacks over the native host" do
      test "open/call/close drive the real host and return verbatim wasm strings" do
        assert {:ok, %{session: session, wasm_digest: digest}} = WasmtimeRuntime.open()

        try do
          # The host-reported digest of the bytes it compiled, equal to the
          # BEAM's own digest of the same file via the behaviour's helper.
          assert digest == @vendored_wasm_sha256
          assert digest == Runtime.bytes_digest(File.read!(WasmtimeRuntime.wasm_path()))

          assert {:ok, version} = WasmtimeRuntime.call(session, :graphlaw_version, [])
          assert version =~ "praxis-graphlaw v"
          assert {:ok, @base_hash} = WasmtimeRuntime.call(session, :graph_hash, [@base])
          assert {:ok, @blake3_abc} = WasmtimeRuntime.call(session, :blake3_hex, ["abc"])
        after
          assert :ok = WasmtimeRuntime.close(session)
        end
      end

      test "call/3 refuses a wrong arity and an unknown function with typed errors" do
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        assert {:error, %{code: :graphlaw_arity_mismatch, expected: 1, got: 0}} =
                 WasmtimeRuntime.call(session, :graph_hash, [])

        assert {:error, %{code: :graphlaw_unsupported_function, function: :no_such_function}} =
                 WasmtimeRuntime.call(session, :no_such_function, [])

        assert :ok = WasmtimeRuntime.close(session)
      end

      test "a session replays its call sequence, so instance-state-dependent answers match" do
        # v006's blank-node graph_hash depends on the wasm instance's state, not
        # only on the graph: one live instance answers a deterministic sequence
        # of different digests. A session must reproduce that sequence, not the
        # first digest every time (which is what a fresh instance per call gives).
        # This pins the same open praxis-graphlaw v26.7.5 defect that
        # test/ash_a2a/sa2a_conformance_test.exs pins; update both together.
        [v006] = v006_vectors()
        assert {:ok, %{session: session}} = WasmtimeRuntime.open()

        sequence =
          try do
            for _ <- 1..3 do
              assert {:ok, digest} = WasmtimeRuntime.call(session, :graph_hash, [v006.base])
              digest
            end
          after
            WasmtimeRuntime.close(session)
          end

        assert {:ok, fresh} = WasmtimeRuntime.graph_hash(v006.base)
        assert hd(sequence) == fresh.value
        assert length(Enum.uniq(sequence)) > 1

        # The same three calls issued in ONE real host process, independently.
        assert {:ok, batch} =
                 WasmtimeRuntime.batch(List.duplicate({"graph_hash", [v006.base]}, 3))

        assert sequence == Enum.map(batch.results, fn {:ok, r} -> r.value end)
      end

      test "the SA2A court accepts it as a runtime and it agrees with the in-BEAM host" do
        wasm = WasmtimeRuntime.wasm_path()

        case WasmexSession.available?(wasm_path: wasm) do
          :ok ->
            # One-vector corpus (the instance-state-dependent v006) copied from
            # the real corpus, so the court runs in seconds rather than a minute.
            dir =
              Path.join(System.tmp_dir!(), "sa2a_wasmtime_#{System.unique_integer([:positive])}")

            File.mkdir_p!(dir)

            try do
              File.cp_r!(
                Path.join(AshA2A.SA2A.Vector.corpus_dir(), "v006_blank_nodes"),
                Path.join(dir, "v006_blank_nodes")
              )

              assert {:error, %{"assertions" => assertions} = receipt} =
                       AshA2A.SA2A.Conformance.run(
                         runtime_a: WasmexSession,
                         runtime_b: WasmtimeRuntime,
                         wasm_path: wasm,
                         corpus_dir: dir
                       )

              assert receipt["runtime_a"]["wasm_digest"] == @vendored_wasm_sha256
              assert receipt["runtime_b"]["wasm_digest"] == @vendored_wasm_sha256

              for name <-
                    ~w(same_wasm same_admission same_output_semantics same_evidence_identity) do
                assert assertions[name]["computed"], "#{name} not computed"
                assert assertions[name]["value"], "#{name} diverged: #{inspect(assertions[name])}"
              end

              # The open v006 falsifier fires identically in both hosts: the
              # unstable digests agree digit-for-digit across the two runtimes.
              identity = assertions["same_input_identity"]
              assert identity["computed"]
              refute identity["value"]

              by_runtime = Map.new(identity["divergences"], &{&1["runtime"], &1})

              assert Map.keys(by_runtime) |> Enum.sort() == [
                       "BEAM/Wasmex",
                       "Native/graphlaw_host"
                     ]

              assert Map.take(by_runtime["BEAM/Wasmex"], ["first", "repeat"]) ==
                       Map.take(by_runtime["Native/graphlaw_host"], ["first", "repeat"])
            after
              File.rm_rf!(dir)
            end

          {:error, reason} ->
            IO.puts("skipped: in-BEAM runtime unavailable: #{inspect(reason)}")
        end
      end

      test "the SA2A court refuses a relabelled native host before any vector runs (S126)" do
        # Both delegates really open, call and close the real native host; only
        # their caller-controlled labels differ. A whitespace-only relabel is
        # refused on the normalized label, an entirely different label on the
        # identity observed from the open sessions (the same session resource
        # is started by WasmtimeRuntime itself, whatever the module says).
        assert {:error, padded} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.PaddedNativeRuntime
                 )

        assert padded.code == :sa2a_identical_runtimes
        assert padded.basis == :label

        assert Runtime.identity(__MODULE__.PaddedNativeRuntime) !=
                 Runtime.identity(WasmtimeRuntime)

        assert {:error, relabelled} =
                 AshA2A.SA2A.Conformance.run(
                   runtime_a: WasmtimeRuntime,
                   runtime_b: __MODULE__.RelabelledNativeRuntime
                 )

        assert relabelled.code == :sa2a_identical_runtimes
        assert relabelled.basis == :observed_executable

        assert [%{"engine_module" => "AshA2A.GraphLaw.WasmtimeRuntime"}] =
                 relabelled.observed_identity
      end
    end

    describe "the native host executes the vendored artifact under Wasmtime" do
      test "reports the engine version out of the wasm itself" do
        assert {:ok, result} = WasmtimeRuntime.graphlaw_version()
        assert result.value =~ "praxis-graphlaw"
        assert result.runtime == "wasmtime"
      end

      test "every result carries cross-checked artifact identity" do
        assert {:ok, result} = WasmtimeRuntime.graph_hash(@base)
        assert {:ok, expected} = WasmtimeRuntime.wasm_digest()

        # The native host independently hashed the bytes it compiled; this
        # assertion is what turns `WASM_A = WASM_B` from an assumption into a
        # checked fact (falsifier #1).
        assert result.wasm_sha256 == expected
        assert result.wasm_sha256 == @vendored_wasm_sha256
        assert result.wasm_bytes == 3_249_361
        assert result.runtime == "wasmtime"
        assert is_binary(result.runtime_version)
        assert result.host =~ "graphlaw_host/"
      end

      test "host graph_hash job (one shared batch) reproduces the S12 canonical identity vector",
           %{pure: pure} do
        assert {:ok, %{value: @base_hash}} = pure[:base]
      end

      test "host graph_hash job (one shared batch) is invariant to prefix label and triple order",
           %{pure: pure} do
        assert {:ok, %{value: base}} = pure[:base]
        assert {:ok, %{value: reordered}} = pure[:reordered]

        assert base == reordered
        assert base == @base_hash
      end

      test "host graph_hash job (one shared batch) separates a graph that differs by one term", %{
        pure: pure
      } do
        assert {:ok, %{value: base}} = pure[:base]
        assert {:ok, %{value: different}} = pure[:different]

        refute base == different
        assert different == @different_hash
      end

      test "host blake3_hex job (one shared batch) reproduces the published BLAKE3 vector for \"abc\"",
           %{pure: pure} do
        assert {:ok, %{value: @blake3_abc}} = pure[:blake3_abc]
      end

      test "run_hooks/3 returns the real admission JSON from the engine" do
        event = """
        @prefix ex: <http://example.org/> .
        ex:c ex:p ex:d .
        """

        assert {:ok, result} = WasmtimeRuntime.run_hooks(@base, event)
        assert {:ok, decoded} = JSON.decode(result.value)
        assert decoded["status"] == "ADMITTED"
        assert is_list(decoded["verdicts"])
      end
    end

    describe "batch/2 (one subprocess, one wasm compile, many jobs)" do
      test "runs the whole conformance vector set in a single host process" do
        jobs = [
          {"graph_hash", [@base]},
          {"graph_hash", [@reordered]},
          {"graph_hash", [@different]},
          {"blake3_hex", ["abc"]}
        ]

        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)
        assert batch.wasm_sha256 == @vendored_wasm_sha256

        assert [
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @base_hash}},
                 {:ok, %{value: @different_hash}},
                 {:ok, %{value: @blake3_abc}}
               ] = batch.results
      end

      test "a bad job inside a batch is typed and does not poison its siblings" do
        assert {:ok, batch} =
                 WasmtimeRuntime.batch([
                   {"graph_hash", [@base]},
                   {"no_such_function", []}
                 ])

        assert [{:ok, %{value: @base_hash}}, {:error, bad}] = batch.results
        assert bad.code == :unsupported_fn
        assert bad.message =~ "no_such_function"
      end

      test "wrong arity is refused by the host rather than trapping the module" do
        assert {:ok, batch} = WasmtimeRuntime.batch([{"graph_hash", []}])
        assert [{:error, bad}] = batch.results
        assert bad.code == :bad_arity
      end
    end

    describe "the finite conformance suite, driven from priv/graphlaw/conformance_vectors.json" do
      test "every recorded vector reproduces exactly under the native Wasmtime host" do
        assert {:ok, doc} = ConformanceVectors.load()
        assert {:ok, jobs} = ConformanceVectors.jobs()
        assert {:ok, batch} = WasmtimeRuntime.batch(jobs)

        # Same artifact the expectations were recorded against -- otherwise
        # agreement would prove nothing about host independence.
        assert batch.wasm_sha256 == doc["wasm_sha256"]
        assert batch.wasm_bytes == doc["wasm_bytes"]

        pairs = Enum.zip(doc["vectors"], batch.results)
        assert length(pairs) == length(doc["vectors"])

        for {vector, result} <- pairs do
          assert {:ok, %{value: value}} = result

          assert value == vector["expect"],
                 "vector #{vector["id"]} diverged under WasmtimeRuntime"
        end
      end

      test "the suite really covers the S12 identity triple and both BLAKE3 vectors" do
        assert {:ok, vectors} = ConformanceVectors.vectors()
        ids = MapSet.new(vectors, & &1["id"])

        for required <- [
              "S12-canonical-base",
              "S12-prefix-label-and-order-invariance",
              "S12-one-term-changed",
              "blake3-abc"
            ] do
          assert MapSet.member?(ids, required), "conformance suite lost vector #{required}"
        end
      end

      test "a missing vector document is a typed refusal, not a crash" do
        assert {:error, %{code: :conformance_vectors_missing}} =
                 ConformanceVectors.load(vectors_path: "/nonexistent/vectors.json")
      end
    end

    describe "real failure modes" do
      # Measured, not assumed: this engine's `graph_hash` is *lenient*. Feeding
      # it malformed Turtle does NOT produce its `{"error": ...}` object -- it
      # produces the canonical hash of whatever triples it managed to parse,
      # which for wholly unparseable input is the empty graph. A caller cannot
      # use "did graph_hash error" as a syntax check; a conformance suite must
      # therefore pin this behaviour rather than assume strictness.
      test "malformed Turtle still hashes: `graph_hash` never reports a syntax error",
           %{pure: pure} do
        for junk <- @junk_inputs do
          assert {:ok, %{value: value}} = pure[{:junk, junk}]
          # A 64-char lowercase hex digest, not an `{"error": ...}` object.
          assert value =~ ~r/\A[0-9a-f]{64}\z/, "unexpected result for #{inspect(junk)}"
        end
      end

      test "input the parser recovers nothing from yields the empty-graph digest",
           %{pure: pure} do
        for empty_equivalent <- ["@@@ bad", "<http://a> <http://b"] do
          assert {:ok, %{value: @empty_graph_hash}} = pure[{:junk, empty_equivalent}]
        end
      end

      test "a lenient parse is still deterministic across separate host processes" do
        junk = "this is not turtle <<<"
        assert {:ok, %{value: first}} = WasmtimeRuntime.graph_hash(junk)
        assert {:ok, %{value: second}} = WasmtimeRuntime.graph_hash(junk)

        # Two independent subprocesses, two independent wasm instantiations.
        assert first == second
        refute first == @empty_graph_hash
      end

      test "the empty-graph digest is BLAKE3 of the empty canonical N-Quads form",
           %{pure: pure} do
        assert {:ok, %{value: @empty_graph_hash}} = pure[:empty_graph]
        assert {:ok, %{value: @empty_graph_hash}} = pure[:blake3_empty]
      end

      test "a non-wasm file is refused at compile time with artifact identity intact" do
        path =
          Path.join(System.tmp_dir!(), "ash_a2a_not_a_wasm_#{System.unique_integer([:positive])}")

        File.write!(path, "definitely not webassembly")

        try do
          assert {:error, error} = WasmtimeRuntime.graph_hash(@base, wasm_path: path)
          assert error.code == :wasm_compile_failed
          # Identity is still reported for the (wrong) artifact: the host
          # hashes what it was handed before it tries to compile it.
          assert error.wasm_sha256 ==
                   Base.encode16(
                     :crypto.hash(:sha256, "definitely not webassembly"),
                     case: :lower
                   )
        after
          File.rm(path)
        end
      end

      test "a deadline that cannot be met kills the subprocess and returns :timeout" do
        # Compiling a 3.2 MB module is seconds-scale work; 1 ms cannot finish.
        assert {:error, %{code: :timeout, timeout_ms: 1}} =
                 WasmtimeRuntime.graph_hash(@base, timeout: 1)
      end
    end

    defp v006_vectors do
      {:ok, vectors} = AshA2A.SA2A.Vector.load_all()
      Enum.filter(vectors, &(&1.id == "v006_blank_nodes"))
    end
  else
    test "SKIPPED: graphlaw_host is not built, so WasmtimeRuntime was not executed" do
      IO.warn("""
      WasmtimeRuntime wasm-execution tests were SKIPPED because the native host is \
      not built at #{WasmtimeRuntime.binary_path()}.

      These tests are never replaced by a mock or a stub. Build the real host \
      and re-run:

          cd native/graphlaw_host && cargo build --release
      """)

      assert {:error, %{code: :graphlaw_host_not_built}} = WasmtimeRuntime.available?()
    end
  end

  defmodule PaddedNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` (every call runs
    the real native host) whose host id carries one trailing space -- the
    one-space relabel RFC-SA2A-002 S126 refuses. Records no interaction.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: WasmtimeRuntime.host_id() <> " "
    @impl true
    def engine_id, do: WasmtimeRuntime.engine_id()
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end

  defmodule RelabelledNativeRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmtimeRuntime` under entirely
    different caller-controlled labels (`"WASI/StandaloneHost"`, `"wasm3"`).
    Only identity observed from the open session (S126) tells it apart.
    """
    @behaviour AshA2A.GraphLaw.Runtime
    alias AshA2A.GraphLaw.WasmtimeRuntime

    @impl true
    def host_id, do: "WASI/StandaloneHost"
    @impl true
    def engine_id, do: "wasm3"
    @impl true
    def available?(opts \\ []), do: WasmtimeRuntime.available?(opts)
    @impl true
    def open(opts \\ []), do: WasmtimeRuntime.open(opts)
    @impl true
    def call(session, fun, args), do: WasmtimeRuntime.call(session, fun, args)
    @impl true
    def close(session), do: WasmtimeRuntime.close(session)
  end
end

# --- SECTION 15: Original test/ash_a2a/receipt_store/actuation_claim_lease_test.exs ---
defmodule AshA2A.ReceiptStore.ActuationClaimLeaseTest do
  @moduledoc """
  RFC-SA2A-001 S55 actuation-claim liveness -- RFC-SA2A-002 ARD S40's
  idempotency-store robustness requirement, one index below the primary
  command claim `AshA2A.ReceiptStore.ClaimLease` already covers (qualified by
  `test/ash_a2a/chicago/crash_reconciliation_test.exs`).

  Exercises `AshA2A.ReceiptStore.ActuationClaimLease` through both real
  backends -- a real `AshA2A.ReceiptStore.Memory` GenServer and a real
  on-disk `EKV` instance (`cluster_size: 1`, the same real-local-EKV pattern
  `test/ash_a2a/receipt_store_ekv_test.exs` uses) -- against a real
  filesystem `AshA2A.ReceiptOutbox`. No Mock/mox/patch/monkeypatch anywhere
  in this file: "abandoned" and "reclaimed" are asserted on the real claim
  results the stores return, not on interaction expectations.

  TQ-06: the lease is injected per call (`claim_lease_ms:` in the store opts)
  at 500ms -- long enough that the "still held" assertion cannot race a GC
  pause or a loaded scheduler -- and expiry is observed with a deadline poll
  instead of a fixed sleep. Nothing here mutates the global
  `:claim_lease_ms`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  @lease_ms 500
  @expiry_deadline_ms 2_000

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)

    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    :ok
  end

  # Polls `fun` until it returns `expected` or the deadline passes; returns the
  # last observed value so a failing assertion shows the real result.
  defp eventually(expected, fun, deadline_ms \\ @expiry_deadline_ms) do
    stop = System.monotonic_time(:millisecond) + deadline_ms
    poll(expected, fun, stop)
  end

  defp poll(expected, fun, stop) do
    case fun.() do
      ^expected ->
        expected

      other ->
        if System.monotonic_time(:millisecond) >= stop do
          other
        else
          # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
          AshA2A.TestSupport.Eventually.pause(25)
          poll(expected, fun, stop)
        end
    end
  end

  defp effect_command(command_id, effect_key) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: command_id,
      agent_id: "s55-lease-agent",
      principal_id: "s55-lease-principal",
      input: %{effect_key: effect_key}
    )
  end

  describe "Memory backend" do
    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned (lease elapsed, no outbox anchor)" do
      name = :"actuation_lease_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name, claim_lease_ms: @lease_ms]

      key = "actuation-lease-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant", key)
      actuation = Actuation.identity(crashed)

      # The crashed claimant's primary command claim...
      assert {:execute, _execution_id} = Memory.claim(crashed, opts)
      # ...and its actuation (effect) claim -- exactly the state a process
      # that died before ever preparing a receipt anchor leaves behind.
      assert :proceed = Memory.claim_actuation(actuation, crashed, opts)

      fresh = effect_command("fresh-claimant", key)

      # Before the lease elapses, a second claimant is refused.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)

      # Past the lease, with no outbox anchor for the crashed claimant's
      # command id -- DO could not have started -- a fresh claimant reclaims
      # the effect instead of being refused forever.
      assert :proceed =
               eventually(:proceed, fn -> Memory.claim_actuation(actuation, fresh, opts) end)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-memory-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Memory.commit_actuation(actuation, receipt, opts)

      later = effect_command("later-claimant", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Memory.claim_actuation(actuation, later, opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor, no matter how long the lease has passed" do
      name = :"actuation_lease_anchored_memory_#{System.unique_integer([:positive])}"
      start_supervised!({Memory, name: name})
      opts = [name: name, claim_lease_ms: 20]

      key = "actuation-anchored-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Memory.claim(claimant, opts)
      assert :proceed = Memory.claim_actuation(actuation, claimant, opts)

      # The claimant reached the pre-DO receipt boundary before "crashing" --
      # DO may already have run.
      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      fresh = effect_command("fresh-claimant-anchored", key)

      # Well past the lease, but the anchor exists: this effect may already
      # have actuated, so the actuation claim must stay in-flight -- the
      # lease alone never reclaims it.
      assert {:error, :actuation_in_flight} = Memory.claim_actuation(actuation, fresh, opts)
    end
  end

  describe "Ekv backend" do
    setup do
      ekv_name = :"actuation_lease_ekv_#{System.unique_integer([:positive])}"

      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ash_a2a_actuation_claim_lease_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(data_dir) end)

      # cluster_size: 1 -- a real single-voter setup, the same real-local-EKV
      # pattern test/ash_a2a/receipt_store_ekv_test.exs already uses.
      start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})

      %{store_opts: [name: ekv_name, claim_lease_ms: @lease_ms]}
    end

    test "an in-flight actuation is reclaimed once its claimant's primary claim is abandoned", %{
      store_opts: store_opts
    } do
      key = "actuation-lease-ekv-#{System.unique_integer([:positive])}"
      crashed = effect_command("crashed-claimant-ekv", key)
      actuation = Actuation.identity(crashed)

      assert {:execute, _execution_id} = Ekv.claim(crashed, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, crashed, store_opts)

      fresh = effect_command("fresh-claimant-ekv", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)

      assert :proceed =
               eventually(:proceed, fn -> Ekv.claim_actuation(actuation, fresh, store_opts) end)

      receipt =
        Receipt.from_reply(
          fresh,
          Identity.execution("lease-ekv-exec"),
          :external_do,
          {:reply, []}
        )

      assert :ok = Ekv.commit_actuation(actuation, receipt, store_opts)

      later = effect_command("later-claimant-ekv", key)

      assert {:duplicate, %Receipt{replayed?: true}} =
               Ekv.claim_actuation(actuation, later, store_opts)
    end

    test "an in-flight actuation is never reclaimed once its claimant's primary claim reached the outbox anchor",
         %{store_opts: store_opts} do
      store_opts = Keyword.put(store_opts, :claim_lease_ms, 20)
      key = "actuation-anchored-ekv-#{System.unique_integer([:positive])}"
      claimant = effect_command("anchored-claimant-ekv", key)
      actuation = Actuation.identity(claimant)

      assert {:execute, execution_id} = Ekv.claim(claimant, store_opts)
      assert :proceed = Ekv.claim_actuation(actuation, claimant, store_opts)

      anchor = Receipt.pending(claimant, execution_id, :external_do)
      :ok = ReceiptOutbox.append(anchor)

      # SLEEP-CLASS: POLL-STEP (audited AshA2A.TestSupport.Eventually.pause)
      AshA2A.TestSupport.Eventually.pause(60)

      fresh = effect_command("fresh-claimant-ekv-anchored", key)
      assert {:error, :actuation_in_flight} = Ekv.claim_actuation(actuation, fresh, store_opts)
    end
  end
end

# --- SECTION 16: Original test/ash_a2a/receipt_store/boot_check_test.exs ---
defmodule AshA2A.ReceiptStore.BootCheckTest do
  @moduledoc """
  Findings R2 / R12 / PERF-09: `AshA2A.ReceiptStore.boot_check/1` refuses
  configurations whose at-most-once proof would not survive a reboot. All
  inputs are passed as opts, so no application env is mutated; paths are
  real directories (the real tmp dir vs. a real non-tmp directory).
  """

  use ExUnit.Case, async: true

  alias AshA2A.ReceiptStore
  alias AshA2A.ReceiptStore.{Ekv, Memory}

  @durable_dir Path.expand("_build_boot_check_durable", File.cwd!())
  @tmp_dir Path.join(System.tmp_dir!(), "ash_a2a_boot_check")

  defp check(opts) do
    ReceiptStore.boot_check(
      Keyword.merge(
        [
          production: false,
          receipt_store: Memory,
          receipt_outbox_dir: nil,
          receipt_store_ekv_opts: [],
          kill_switch_path: nil,
          allow_memory_receipt_store: false
        ],
        opts
      )
    )
  end

  test "a durable store with a tmp or unset outbox dir is refused" do
    ekv = [data_dir: @durable_dir]

    assert {:error, {:non_durable_outbox_dir, nil}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv)

    assert {:error, {:non_durable_outbox_dir, @tmp_dir}} =
             check(receipt_store: Ekv, receipt_store_ekv_opts: ekv, receipt_outbox_dir: @tmp_dir)

    assert :ok =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: ekv,
               receipt_outbox_dir: @durable_dir
             )
  end

  test "Ekv with a tmp data_dir is refused" do
    assert {:error, {:non_durable_receipt_store_data_dir, @tmp_dir}} =
             check(
               receipt_store: Ekv,
               receipt_store_ekv_opts: [data_dir: @tmp_dir],
               receipt_outbox_dir: @durable_dir
             )
  end

  test "production refuses an implicit store, the Memory store, a small cluster, and a volatile kill switch" do
    assert {:error, :receipt_store_not_configured} =
             ReceiptStore.boot_check(production: true, receipt_store: nil)

    assert {:error, {:non_durable_receipt_store, Memory}} =
             check(production: true, receipt_store: Memory)

    durable_ekv = [
      production: true,
      receipt_store: Ekv,
      receipt_outbox_dir: @durable_dir,
      receipt_store_ekv_opts: [data_dir: @durable_dir, cluster_size: 1]
    ]

    assert {:error, {:insufficient_cluster_size, 1}} = check(durable_ekv)

    three =
      Keyword.put(durable_ekv, :receipt_store_ekv_opts, data_dir: @durable_dir, cluster_size: 3)

    assert {:error, {:non_durable_kill_switch_path, nil}} = check(three)

    assert :ok = check(Keyword.put(three, :kill_switch_path, Path.join(@durable_dir, "ks.dets")))

    # Escape hatch for Memory is explicit and still needs a durable kill switch.
    assert :ok =
             check(
               production: true,
               receipt_store: Memory,
               allow_memory_receipt_store: true,
               kill_switch_path: Path.join(@durable_dir, "ks.dets")
             )
  end

  test "non-production Memory with defaults stays bootable (backwards compatible)" do
    assert :ok = check([])
  end

  test "durable_path?/1 rejects the tmp dir under any spelling" do
    refute ReceiptStore.durable_path?(nil)
    refute ReceiptStore.durable_path?("")
    refute ReceiptStore.durable_path?(System.tmp_dir!())
    refute ReceiptStore.durable_path?(Path.join(System.tmp_dir!(), "x/y"))
    refute ReceiptStore.durable_path?("/tmp/ash_a2a")
    assert ReceiptStore.durable_path?(@durable_dir)
  end
end

# --- SECTION 17: Original test/ash_a2a/receipt_store/store_hardening_test.exs ---
defmodule AshA2A.ReceiptStore.StoreHardeningTest do
  @moduledoc """
  Findings R1 (lost actuation commit must not re-open a completed effect),
  R4 (execution-id fencing), and R12/PERF-09 (bounded Memory state) against
  both real backends: a real `AshA2A.ReceiptStore.Memory` GenServer and a
  real on-disk `EKV` (`cluster_size: 1`), with a real filesystem
  `AshA2A.ReceiptOutbox`. Assertions are on the real results the stores
  return; no mocks.

  Leases are injected per call (`claim_lease_ms:` in store opts, TQ-06), so
  nothing here mutates the global `:claim_lease_ms`.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard
  @moduletag :tmp_dir

  alias AshA2A.{Actuation, Command, Identity, Receipt, ReceiptOutbox}
  alias AshA2A.ReceiptStore.{ActuationClaimLease, Ekv, Memory}

  setup %{tmp_dir: tmp_dir} do
    previous_outbox = Application.get_env(:ash_a2a, :receipt_outbox_dir)
    Application.put_env(:ash_a2a, :receipt_outbox_dir, Path.join(tmp_dir, "outbox"))

    on_exit(fn ->
      case previous_outbox do
        nil -> Application.delete_env(:ash_a2a, :receipt_outbox_dir)
        value -> Application.put_env(:ash_a2a, :receipt_outbox_dir, value)
      end
    end)

    :ok
  end

  defp effect_command(command_id, effect_key) do
    Command.new("AshA2A.Test.Fixture.CountingActuator.actuate",
      command_id: command_id,
      agent_id: "hardening-agent",
      principal_id: "hardening-principal",
      input: %{effect_key: effect_key}
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp memory_opts(extra \\ []) do
    name = :"store_hardening_memory_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, [name: name] ++ extra})
    [name: name]
  end

  defp ekv_opts do
    ekv_name = :"store_hardening_ekv_#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "ash_a2a_store_hardening_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(data_dir) end)
    start_supervised!({EKV, name: ekv_name, data_dir: data_dir, cluster_size: 1})
    [name: ekv_name]
  end

  # --- R1 ------------------------------------------------------------------

  for backend <- [Memory, Ekv] do
    @backend backend

    describe "R1 #{inspect(backend)}" do
      setup do
        %{opts: if(@backend == Memory, do: memory_opts(), else: ekv_opts())}
      end

      test "a completed effect whose actuation commit was lost answers {:duplicate, primary receipt}, never :proceed",
           %{opts: opts} do
        store = @backend
        key = unique("r1")
        first = effect_command(unique("r1-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        # DO ran and the PRIMARY receipt committed, but commit_actuation/3
        # was lost (process died / store call failed between the two).
        receipt =
          first
          |> Receipt.pending(execution_id, :external_do)
          |> Receipt.finalize({:reply, 1})

        assert :ok = store.commit(receipt, opts)

        # No anchor remains (commit removed it) and the lease is 0: before
        # R1 this reclaimed the effect and DO ran a second time.
        retry = effect_command(unique("r1-retry"), key)

        assert {:duplicate, %Receipt{replayed?: true} = dup} =
                 store.claim_actuation(actuation, retry, opts ++ [claim_lease_ms: 0])

        assert dup.receipt_id == receipt.receipt_id

        # The entry was healed: a later claimant is answered from the
        # actuation index itself.
        assert {:duplicate, _} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-later"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is a pre-DO refusal is reclaimable", %{opts: opts} do
        store = @backend
        key = unique("r1-refused")
        first = effect_command(unique("r1-refused-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)

        refusal =
          Receipt.from_reply(
            first,
            execution_id,
            :external_do,
            {:error, %{code: :receipt_anchor_unavailable, detail: "anchor"}}
          )

        assert refusal.terminal_status == :refused
        assert :ok = store.commit(refusal, opts)

        assert :proceed =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-refused-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      test "a claimant whose primary receipt is still :pending stays in flight", %{opts: opts} do
        store = @backend
        key = unique("r1-pending")
        first = effect_command(unique("r1-pending-first"), key)
        actuation = Actuation.identity(first)

        assert {:execute, execution_id} = store.claim(first, opts)
        assert :proceed = store.claim_actuation(actuation, first, opts)
        assert :ok = store.commit(Receipt.pending(first, execution_id, :external_do), opts)

        assert {:error, :actuation_in_flight} =
                 store.claim_actuation(
                   actuation,
                   effect_command(unique("r1-pending-retry"), key),
                   opts ++ [claim_lease_ms: 0]
                 )
      end

      # --- R4 --------------------------------------------------------------

      test "commit is fenced on execution id: a reclaimed claim refuses the stale executor",
           %{opts: opts} do
        store = @backend
        command = effect_command(unique("r4"), unique("r4-key"))

        assert {:execute, stale} = store.claim(command, opts)
        # Lease 0 and no anchor: the claim is abandoned and reclaimed.
        assert {:execute, current} = store.claim(command, opts ++ [claim_lease_ms: 0])
        refute stale == current

        assert {:error, :stale_execution} = store.confirm_claim(command.command_id, stale, opts)
        assert :ok = store.confirm_claim(command.command_id, current, opts)

        stale_receipt =
          command |> Receipt.pending(stale, :external_do) |> Receipt.finalize({:reply, :stale})

        current_receipt =
          command
          |> Receipt.pending(current, :external_do)
          |> Receipt.finalize({:reply, :current})

        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)
        assert :ok = store.commit(current_receipt, opts)
        # The stale executor still cannot overwrite after the fact.
        assert {:error, :stale_execution} = store.commit(stale_receipt, opts)

        assert {:ok, %Receipt{reply: {:reply, :current}}} = store.fetch(command.command_id, opts)
      end
    end
  end

  test "ActuationClaimLease.decide/3 never reclaims behind a finalized primary receipt" do
    command = effect_command(unique("decide"), unique("decide-key"))
    execution_id = Identity.execution("decide-exec")

    receipt =
      command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert {:duplicate, ^receipt} =
             ActuationClaimLease.decide(
               %{receipt: receipt, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )

    refute ActuationClaimLease.abandoned?(
             %{receipt: receipt, claimed_at: nil},
             command.command_id,
             claim_lease_ms: 0
           )

    assert :reclaim =
             ActuationClaimLease.decide(
               %{receipt: nil, claimed_at: nil},
               command.command_id,
               claim_lease_ms: 0
             )
  end

  # --- R12 / PERF-09 ---------------------------------------------------------

  test "Memory TTL sweep evicts only committed entries older than the TTL" do
    opts = memory_opts(receipt_ttl_ms: 50, sweep_interval_ms: 3_600_000)

    committed = effect_command(unique("ttl-committed"), unique("k"))
    in_flight = effect_command(unique("ttl-inflight"), unique("k"))

    assert {:execute, execution_id} = Memory.claim(committed, opts)
    assert {:execute, _} = Memory.claim(in_flight, opts)

    receipt =
      committed |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    assert :ok = Memory.commit(receipt, opts)
    assert Memory.size(opts) == 2

    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(80)

    assert 1 = Memory.sweep(opts)
    assert Memory.size(opts) == 1
    assert :error = Memory.fetch(committed.command_id, opts)
    # The in-flight claim survives the sweep.
    assert {:error, :in_flight} = Memory.claim(in_flight, opts)
  end

  test "Memory max_entries evicts the oldest committed receipts first, never in-flight claims" do
    opts = memory_opts(max_entries: 2)

    [a, b, c] =
      for label <- ["a", "b", "c"] do
        command = effect_command(unique("max-#{label}"), unique("k"))
        assert {:execute, execution_id} = Memory.claim(command, opts)

        receipt =
          command |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

        assert :ok = Memory.commit(receipt, opts)
        command
      end

    assert Memory.size(opts) == 2
    assert :error = Memory.fetch(a.command_id, opts)
    assert {:ok, _} = Memory.fetch(b.command_id, opts)
    assert {:ok, _} = Memory.fetch(c.command_id, opts)

    # In-flight entries are never evicted, even over the bound.
    for label <- ["x", "y", "z"] do
      assert {:execute, _} =
               Memory.claim(effect_command(unique("inflight-#{label}"), unique("k")), opts)
    end

    assert Memory.size(opts) == 5
  end

  test "Memory TTL sweep keeps a committed primary still referenced by an in-flight actuation entry" do
    opts = memory_opts(receipt_ttl_ms: 20, sweep_interval_ms: 3_600_000)
    key = unique("pinned")
    first = effect_command(unique("pinned-first"), key)
    actuation = Actuation.identity(first)

    assert {:execute, execution_id} = Memory.claim(first, opts)
    assert :proceed = Memory.claim_actuation(actuation, first, opts)

    receipt =
      first |> Receipt.pending(execution_id, :external_do) |> Receipt.finalize({:reply, 1})

    # The primary commit landed; the actuation commit was lost (R1 shape).
    assert :ok = Memory.commit(receipt, opts)
    # SLEEP-CLASS: REAL-INTERVAL (audited AshA2A.TestSupport.Eventually.pause)
    AshA2A.TestSupport.Eventually.pause(40)

    # The expired primary is the only evidence the effect completed: the
    # sweep must keep it, or the effect would be refused forever.
    assert 0 = Memory.sweep(opts)
    assert {:ok, _} = Memory.fetch(first.command_id, opts)

    assert {:duplicate, %Receipt{} = dup} =
             Memory.claim_actuation(
               actuation,
               effect_command(unique("pinned-retry"), key),
               opts ++ [claim_lease_ms: 0]
             )

    assert dup.receipt_id == receipt.receipt_id
  end

  test "Ekv.confirm_claim/3 answers a failed consistent read with a typed refusal, never a raise",
       %{tmp_dir: tmp_dir} do
    # A real EKV member with no CAS config: `EKV.get(_, _, consistent: true)`
    # raises there, exactly as it does on quorum loss.
    name = :"store_hardening_ekv_nocas_#{System.unique_integer([:positive])}"
    start_supervised!({EKV, name: name, data_dir: Path.join(tmp_dir, "ekv-nocas")})
    command = effect_command(unique("nocas"), unique("k"))

    assert {:error, :receipt_store_unavailable} =
             Ekv.confirm_claim(command.command_id, Identity.execution("nocas-exec"), name: name)
  end

  test "a legacy bare-map start still yields a working store (backwards compatible init)" do
    name = :"store_hardening_legacy_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(Memory, %{}, name: name)
    on_exit(fn -> AshA2A.TestSupport.SafeStop.stop(pid) end)

    command = effect_command(unique("legacy"), unique("k"))
    assert {:execute, _} = Memory.claim(command, name: name)
  end

  test "an outbox entry for one command does not anchor another (R5 scoping at the store)" do
    opts = memory_opts()
    torn_owner = effect_command(unique("torn-owner"), unique("k"))
    other = effect_command(unique("other"), unique("k"))

    File.mkdir_p!(ReceiptOutbox.dir())

    File.write!(
      ReceiptOutbox.entry_path_for(torn_owner.command_id, Identity.runtime("torn")),
      <<131, 104>>
    )

    assert {:execute, _} = Memory.claim(torn_owner, opts)
    assert {:execute, _} = Memory.claim(other, opts)

    # The torn file blocks reclaim of its own command only.
    assert {:error, :in_flight} = Memory.claim(torn_owner, opts ++ [claim_lease_ms: 0])
    assert {:execute, _} = Memory.claim(other, opts ++ [claim_lease_ms: 0])
  end
end

# --- SECTION 18: Original test/ash_a2a/research/erc_sanitize_test.exs ---
defmodule AshA2A.Research.ERCSanitizeTest do
  @moduledoc "CWE-22 court: traversal ids never write outside the receipt dir. DB-free."
  use ExUnit.Case, async: true

  alias AshA2A.Research.ERC

  defp attrs(id),
    do: %{id: id, claim: "c", falsifier: "f", state: :observed, evidence: %{"n" => 1}}

  defp tree(dir), do: dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.sort()

  @tag :tmp_dir
  test "traversal and separator ids are refused; nothing escapes the dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    before = tree(tmp)

    for bad <- [
          "../evil",
          "../../evil",
          "a/b",
          "a\\b",
          "..",
          "x/../../y",
          "/abs",
          "",
          ".hidden",
          "a\0b",
          String.duplicate("a", 200)
        ] do
      assert_raise ArgumentError, ~r/refused_erc_id/, fn -> ERC.emit!(attrs(bad), dir: dir) end
    end

    assert tree(tmp) == before
    refute File.exists?(Path.join(tmp, "evil-1.json"))
  end

  @tag :tmp_dir
  test "a normal id writes exactly one file inside dir", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "erc")
    assert {:ok, path} = ERC.emit!(attrs("ERC-001"), dir: dir)
    assert Path.dirname(path) == dir
    assert File.exists?(path)
    assert [_] = File.ls!(dir)
  end
end

# --- SECTION 19: Original test/ash_a2a/sa2a/conformance/mix_project_stack_test.exs ---
defmodule AshA2A.SA2A.Conformance.MixProjectStackTest do
  # Not async: asserts on the process-global Mix project stack.
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.Checks.C2

  # `project_info/2` evaluates a sibling project's real mix.exs. `use
  # Mix.Project` pushes that module onto the global Mix project stack when it
  # compiles, and a stack that still holds the sibling makes every later
  # `Mix.Task.run("app.start")` in this VM compile the sibling project and
  # prune the code path (whole-suite `{:error, :bad_name}` / "module not
  # available" cascade). Evaluating a project must leave the stack as found.
  test "evaluating a sibling mix.exs leaves the Mix project stack unchanged" do
    root = Path.join(System.tmp_dir!(), "mps-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "sibling")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MixProjectStackTest.Sibling#{System.unique_integer([:positive])}.MixProject do
      use Mix.Project
      def project, do: [app: :mps_sibling, version: "0.0.1", deps: []]
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    before = Mix.Project.get()
    assert {:ok, %{app: :mps_sibling}} = C2.project_info(%{root: root}, "sibling")
    assert Mix.Project.get() == before
    assert Mix.Project.get() == AshA2A.MixProject
  end

  test "the real actuator/ and authority_service/ projects evaluate without leaking either" do
    root = File.cwd!()
    before = Mix.Project.get()
    assert {:ok, %{app: :actuator}} = C2.project_info(%{root: root}, "actuator")
    assert {:ok, %{app: :authority_service}} = C2.project_info(%{root: root}, "authority_service")
    assert Mix.Project.get() == before
  end
end

# --- SECTION 20: Original test/ash_a2a/sa2a/conformance/profiles_test.exs ---
defmodule AshA2A.SA2A.Conformance.ProfilesTest do
  @moduledoc """
  Courts for the computed conformance gate (`mix ash_a2a.verify_conformance
  --profile c0|c1|c2|c3`).

  Chicago style: every collaborator is real. Fixtures are real git repositories,
  real mix projects, real compiled BEAM binaries and real Ed25519 keys; oracles
  (`:crypto.generate_key/2`, `git`, the filesystem) are independent of the code
  under test. DB-free: no Repo, no Oban, no app-env mutation (every input is
  passed through `opts`).

  The only test double is a fake `gh` executable script in the supply-chain
  tests: a real `gh` needs network and an authenticated GitHub repository, which
  is not realistically available in-process; the script is a real executable
  that answers on stdout/exit code, not an interaction-verifying mock.
  """
  use ExUnit.Case, async: false

  alias AshA2A.SA2A.Conformance.{Check, Claim, Profiles}
  alias AshA2A.SA2A.Conformance.Checks.{C0, C1, C2, C3, Supply}

  @moduletag :conformance_profiles

  # ---------------------------------------------------------------- helpers

  defp uniq, do: System.unique_integer([:positive])

  defp tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "sa2a_conf_#{label}_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
          args,
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp git_repo(label) do
    dir = tmp_dir(label)
    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.txt"), "a")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  defp compile_fixture(source) do
    # The compiler may warn about fixture type mismatches; that noise is irrelevant.
    {result, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

    [{mod, bin}] = result
    {mod, bin}
  end

  defp fixture_module(body) do
    name = "AshA2A.Test.ConfFixture#{uniq()}"
    compile_fixture("defmodule #{name} do\n#{body}\nend")
  end

  # ------------------------------------------------------------- Check core

  describe "Check" do
    test "run/2 converts a raising probe into :fail, never a crash or a pass" do
      check = Check.run("x.boom", :c0, "boom", fn -> raise "kaboom" end)
      assert check.status == :fail
      assert check.evidence =~ "kaboom"
    end

    test "run/2 rejects a probe that returns something other than a status tuple" do
      check = Check.run("x.bad", :c0, "bad", fn -> :ok end)
      assert check.status == :fail
      assert check.evidence =~ "malformed"
    end

    test "run/2 keeps pass, fail and unverified distinct" do
      assert Check.run("a", :c0, "t", fn -> {:pass, "e"} end).status == :pass
      assert Check.run("a", :c0, "t", fn -> {:fail, "e"} end).status == :fail
      assert Check.run("a", :c0, "t", fn -> {:unverified, "e"} end).status == :unverified
    end
  end

  # -------------------------------------------------------------------- C0

  describe "C0 checks" do
    test "refusal totality holds both ways on the real refusal registry" do
      assert {:pass, ev} = C0.refusal_totality()
      assert ev =~ "unknown"
    end

    test "standing is derived from evidence, never accepted as a literal" do
      assert {:pass, _} = C0.standing_derived()
    end

    test "canonical digest is key-order invariant and value sensitive" do
      assert {:pass, _} = C0.canonical_digest()
    end

    test "subject identity passes on a clean git checkout and names the sha" do
      repo = git_repo("clean")
      sha = git!(repo, ["rev-parse", "HEAD"])
      assert {:pass, ev} = C0.subject_identity(%{root: repo})
      assert ev =~ sha
    end

    test "subject identity fails on a dirty tree (sha does not describe the tree)" do
      repo = git_repo("dirty")
      File.write!(Path.join(repo, "b.txt"), "uncommitted")
      assert {:fail, ev} = C0.subject_identity(%{root: repo})
      assert ev =~ "dirty"
    end

    test "subject identity is unverified outside a git checkout" do
      assert {:unverified, _} = C0.subject_identity(%{root: tmp_dir("nogit")})
    end
  end

  # -------------------------------------------------------------------- C1

  describe "C1 security profile" do
    test ":strict passes; :dev_bypass and :legacy_compat fail; absent module fails" do
      {strict, _} = fixture_module("def current, do: :strict")
      {bypass, _} = fixture_module("def current, do: :dev_bypass")
      {legacy, _} = fixture_module("def current, do: :legacy_compat")

      assert {:pass, _} = C1.security_profile_strict(%{security_profile_module: strict})
      assert {:fail, ev} = C1.security_profile_strict(%{security_profile_module: bypass})
      assert ev =~ "dev_bypass"
      assert {:fail, _} = C1.security_profile_strict(%{security_profile_module: legacy})
      assert {:fail, ev} = C1.security_profile_strict(%{security_profile_module: Nope.Missing})
      assert ev =~ "absent"
    end
  end

  describe "C1 closure report" do
    test "zero violating edges passes, any edge fails, absent court fails" do
      {clean, _} = fixture_module("def report, do: %{violating_edges: []}")

      {dirty, _} =
        fixture_module("def report, do: %{violating_edges: [{A, :b}, {C, :d}]}")

      assert {:pass, _} = C1.closure_report(%{closure_module: clean})
      assert {:fail, ev} = C1.closure_report(%{closure_module: dirty})
      assert ev =~ "2"
      assert {:fail, ev} = C1.closure_report(%{closure_module: Nope.Missing})
      assert ev =~ "absent"
    end
  end

  describe "C1 command bus does not call the dispatcher directly" do
    test "compiled imports with a Dispatcher.dispatch call fail; without pass" do
      {direct, direct_bin} =
        fixture_module("def go(a), do: AshA2A.Dispatcher.dispatch(a, a, a, a, a, [])")

      {via_kernel, kernel_bin} = fixture_module("def go(a), do: {:ok, a}")

      assert {:fail, ev} =
               C1.command_bus_no_direct_dispatch(%{
                 command_bus: direct,
                 beam_binaries: %{direct => direct_bin}
               })

      assert ev =~ "Dispatcher"

      assert {:pass, _} =
               C1.command_bus_no_direct_dispatch(%{
                 command_bus: via_kernel,
                 beam_binaries: %{via_kernel => kernel_bin}
               })
    end

    test "the real CommandBus in this tree routes every dispatch through the kernel (PASS)" do
      # W4 moved the CommandBus's dispatcher call behind ConsequenceKernel.Dispatch.Inversion;
      # the compiled CommandBus no longer imports AshA2A.Dispatcher (this was a known FAIL).
      assert {:pass, _} = C1.command_bus_no_direct_dispatch(%{})
    end
  end

  describe "C1 canonical digest boundary" do
    test "term_to_binary in a listed module fails; Canonical.digest passes" do
      {legacy, legacy_bin} =
        fixture_module(
          "def d(t), do: :crypto.hash(:sha256, :erlang.term_to_binary(t, [:deterministic]))"
        )

      {canon, canon_bin} =
        fixture_module("def d(t), do: AshA2A.Identity.Canonical.digest(t)")

      {pure, pure_bin} = fixture_module("def d(t), do: t")

      assert {:fail, ev} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [legacy],
                 beam_binaries: %{legacy => legacy_bin}
               })

      assert ev =~ "term_to_binary"

      assert {:pass, _} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [canon, pure],
                 beam_binaries: %{canon => canon_bin, pure => pure_bin}
               })
    end

    test "a module that hashes without Canonical fails" do
      {raw, raw_bin} = fixture_module("def d(t), do: :crypto.hash(:sha256, inspect(t))")

      assert {:fail, ev} =
               C1.canonical_at_boundaries(%{
                 boundary_modules: [raw],
                 beam_binaries: %{raw => raw_bin}
               })

      assert ev =~ "Canonical"
    end

    test "the real C2.PreparedEffect no longer uses term_to_binary (portable RFC 8785 identity, PR #62)" do
      assert {:pass, ev} = C1.canonical_at_boundaries(%{})
      assert ev =~ "no term_to_binary"
      assert ev =~ "Identity.Canonical"
    end
  end

  describe "C1 durable claim store" do
    test "a durable store passes; Memory and ETS stores fail; unset fails" do
      {durable, _} =
        fixture_module("""
        def durable?, do: true
        def claim(_d, _g), do: :ok
        def complete(_d, _r), do: :ok
        """)

      assert {:pass, _} = C1.durable_claim_store(%{claim_store: durable})
      assert {:fail, ev} = C1.durable_claim_store(%{claim_store: AshA2A.C2.MemoryClaimStore})
      assert ev =~ "durable"
      assert {:fail, _} = C1.durable_claim_store(%{claim_store: AshA2A.C2.ClaimStoreETS})
      assert {:fail, ev} = C1.durable_claim_store(%{claim_store: nil})
      assert ev =~ "not configured"
    end
  end

  describe "C1 keyed non-tmp journal" do
    defp keyed(key), do: {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: key]}

    test "durable dir plus a working key provider passes" do
      dir = Path.join(File.cwd!(), "tmp/conf_journal_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:pass, _} =
               C1.keyed_journal(%{
                 journal_dir: dir,
                 journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
               })
    end

    test "a tmp journal dir fails even with a key" do
      dir = Path.join(tmp_dir("journal"), "j")

      assert {:fail, ev} =
               C1.keyed_journal(%{
                 journal_dir: dir,
                 journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
               })

      assert ev =~ "tmp"
    end

    test "a missing or short key fails; an unset dir fails" do
      dir = Path.join(File.cwd!(), "tmp/conf_journal_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:fail, _} = C1.keyed_journal(%{journal_dir: dir, journal_key_provider: nil})

      assert {:fail, ev} =
               C1.keyed_journal(%{journal_dir: dir, journal_key_provider: keyed("short")})

      assert ev =~ "key"
      assert {:fail, _} = C1.keyed_journal(%{journal_dir: nil, journal_key_provider: nil})
    end
  end

  # -------------------------------------------------------------------- C2

  describe "C2 certificate verifier refuses garbage signatures" do
    test "the real CertificateVerifier (crypto lane landed) refuses bad signatures and accepts a good one" do
      assert {:pass, ev} = C2.certificate_verifier_signatures(%{})
      assert ev =~ "refused"
    end

    test "REVERT-MUTATION: the pre-crypto verifier (algorithm-atom check only) is FAILED as ACCEPTING garbage" do
      {legacy, _} =
        fixture_module("""
        def verify(c, e, ctx) do
          with :ok <- AshA2A.C2.CompleteMediation.admit(e, c, ctx),
               true <-
                 Enum.all?(c.signatures, fn s ->
                   Map.get(s, :alg, Map.get(s, :algorithm)) in [:eddsa, "EdDSA"] or true
                 end),
               do: :ok,
               else: (_ -> {:error, :certificate_refused})
        end
        """)

      assert {:fail, ev} = C2.certificate_verifier_signatures(%{certificate_verifier: legacy})
      assert ev =~ "ACCEPTED"
    end

    test "a verifier that refuses everything is not mistaken for one that verifies" do
      {always_refuse, _} = fixture_module("def verify(_c, _e, _ctx), do: {:error, :refused}")

      assert {:unverified, ev} =
               C2.certificate_verifier_signatures(%{certificate_verifier: always_refuse})

      assert ev =~ "positive control"
    end

    test "a verifier that accepts an unsigned certificate fails" do
      {lax, _} =
        fixture_module("""
        def verify(c, e, ctx) do
          with :ok <- AshA2A.C2.CompleteMediation.admit(e, c, ctx), do: (
            if Enum.any?(c.signatures, &(Map.get(&1, :signature) == <<>>)), do: {:error, :x}, else: :ok
          )
        end
        """)

      assert {:fail, _} = C2.certificate_verifier_signatures(%{certificate_verifier: lax})
    end
  end

  describe "C2 crypto verifier primitives" do
    test "real Ed25519 verifies, garbage/wrong-size inputs are refused without raising, ML-DSA refuses a wrong-suite key" do
      assert {:pass, ev} = C2.crypto_verifier_primitives(%{})
      assert ev =~ "ML-DSA"
    end
  end

  describe "C2 separate authority_service and actuator projects" do
    defp project(root, dir, app, deps, opts \\ []) do
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      mod = "Fixture#{uniq()}.MixProject"

      File.write!(Path.join(path, "mix.exs"), """
      defmodule #{mod} do
        use Mix.Project
        def project, do: [app: :#{app}, version: "0.1.0", deps: deps()]
        def application, do: []
        defp deps, do: #{inspect(deps)}
      end
      """)

      if env_sh = opts[:env_sh] do
        rel = Path.join(path, "_build/prod/rel/#{app}/releases/0.1.0")
        File.mkdir_p!(rel)
        File.write!(Path.join(rel, "env.sh"), env_sh)
      end

      if tpl = opts[:env_template] do
        File.mkdir_p!(Path.join(path, "rel"))
        File.write!(Path.join(path, "rel/env.sh.eex"), tpl)
      end

      path
    end

    test "absent projects fail with a precise reason" do
      root = tmp_dir("noproj")
      assert {:fail, ev} = C2.separate_project(%{root: root}, "authority_service")
      assert ev =~ "authority_service"
      assert {:fail, _} = C2.separate_project(%{root: root}, "actuator")
    end

    test "a project with no dependency on the control plane passes" do
      root = tmp_dir("proj_ok")
      project(root, "actuator", :fixture_actuator, [])

      assert {:pass, _} =
               C2.separate_project(%{root: root, control_plane_app: :ash_a2a}, "actuator")
    end

    test "a project depending on the control plane app fails" do
      root = tmp_dir("proj_dep")
      project(root, "actuator", :fixture_actuator2, [{:ash_a2a, path: ".."}])

      assert {:fail, ev} =
               C2.separate_project(%{root: root, control_plane_app: :ash_a2a}, "actuator")

      assert ev =~ "ash_a2a"
    end

    test "release distribution none: source and built release both required" do
      root = tmp_dir("dist")
      env = "export RELEASE_DISTRIBUTION=none\n"

      project(root, "actuator", :dist_full, [], env_template: env, env_sh: env)

      assert {:pass, _} =
               C2.release_distribution_none(%{root: root, control_plane_app: :ash_a2a}, [
                 {"actuator", :dist_full}
               ])

      root2 = tmp_dir("dist_src_only")
      project(root2, "actuator", :dist_src, [], env_template: env)

      assert {:unverified, ev} =
               C2.release_distribution_none(%{root: root2}, [{"actuator", :dist_src}])

      assert ev =~ "release"

      root3 = tmp_dir("dist_bad")
      project(root3, "actuator", :dist_bad, [], env_template: "# nothing\n")

      assert {:fail, _} = C2.release_distribution_none(%{root: root3}, [{"actuator", :dist_bad}])

      root4 = tmp_dir("dist_builtbad")

      project(root4, "actuator", :dist_bb, [],
        env_template: env,
        env_sh: "export RELEASE_DISTRIBUTION=sname\n"
      )

      assert {:fail, _} = C2.release_distribution_none(%{root: root4}, [{"actuator", :dist_bb}])
    end
  end

  describe "C2 no signing key material reachable from control-plane config" do
    test "PEM private key, private-key named entries and signing env vars fail" do
      pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"

      assert {:fail, ev} =
               C2.no_signing_key_material(%{app_env: [some: [nested: pem]], env: %{}})

      assert ev =~ "PEM"

      assert {:fail, _} =
               C2.no_signing_key_material(%{app_env: [signing_key: "abc"], env: %{}})

      assert {:fail, _} =
               C2.no_signing_key_material(%{
                 app_env: [],
                 env: %{"SA2A_SIGNING_KEY" => "abc"}
               })

      assert {:fail, _} =
               C2.no_signing_key_material(%{
                 app_env: [jwk: %{"kty" => "EC", "d" => "secret"}],
                 env: %{}
               })
    end

    test "public-only config passes" do
      assert {:pass, _} =
               C2.no_signing_key_material(%{
                 app_env: [public_key: "MFkw", registry_url: "https://x"],
                 env: %{"PATH" => "/bin"}
               })
    end

    test "the real control-plane config currently carries no signing key material" do
      assert {:pass, _} = C2.no_signing_key_material(%{})
    end
  end

  # -------------------------------------------------------------------- C3

  describe "C3 signer-set quorum" do
    defp quorum_module(body \\ nil) do
      fixture_module(
        body ||
          """
          def quorum(standings, k) do
            valid = for {:valid, %{custodian_id: c} = s} <- standings, do: {c, s}
            custodians = valid |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
            kids = valid |> Enum.map(fn {_, s} -> s.kid end) |> Enum.uniq()

            if length(custodians) >= k and length(kids) == length(valid) and
                 Enum.all?(standings, &match?({:valid, _}, &1)) do
              tier = valid |> Enum.map(fn {_, s} -> s.tier end) |> Enum.min_by(&Atom.to_string/1)
              {:ok, %{custodians: custodians, tier: tier}}
            else
              {:error, :quorum_not_met}
            end
          end
          """
      )
    end

    test "the current SignerSet is a standing-based custodian-distinct quorum (landed, PASS)" do
      assert {:pass, ev} = C3.signer_set_quorum(%{})
      assert ev =~ "custodian-distinct quorum accepted"
      assert ev =~ "two keys of one custodian refused"
    end

    test "a standing-based custodian-distinct quorum, proven end to end with real keys, passes" do
      {mod, _} = quorum_module()
      assert {:pass, ev} = C3.signer_set_quorum(%{signer_set: mod})
      assert ev =~ "custodian"
    end

    test "a quorum that counts distinct kids under one custodian fails" do
      {lax, _} =
        fixture_module("""
        def quorum(standings, k) do
          kids = for {:valid, %{kid: kid}} <- standings, uniq: true, do: kid
          if length(kids) >= k, do: {:ok, %{custodians: kids, tier: :i2}}, else: {:error, :no}
        end
        """)

      assert {:fail, ev} = C3.signer_set_quorum(%{signer_set: lax})
      assert ev =~ "ACCEPTED"
    end

    test "a quorum that ignores invalid standings fails" do
      {lax, _} =
        fixture_module("""
        def quorum(standings, k) do
          if length(standings) >= k, do: {:ok, %{custodians: [1, 2], tier: :i1}}, else: {:error, :no}
        end
        """)

      assert {:fail, _} = C3.signer_set_quorum(%{signer_set: lax})
    end
  end

  # ---------------------------------------------------------- supply chain

  describe "supply chain block" do
    defp fake_gh(dir, body) do
      path = Path.join(dir, "gh")
      File.write!(path, "#!/bin/sh\n" <> body <> "\n")
      File.chmod!(path, 0o755)
      path
    end

    test "without --github every supply check is :unverified" do
      checks = Supply.checks(%{github: false, root: tmp_dir("nogh")})
      assert length(checks) == 3
      assert Enum.all?(checks, &(&1.status == :unverified))
      assert Enum.all?(checks, &(&1.evidence =~ "--github"))
    end

    test "protected main: real gh-shaped answers" do
      dir = tmp_dir("gh")
      ok = fake_gh(dir, ~s(echo '{"enforce_admins":{"enabled":true}}'))
      assert {:pass, _} = Supply.protected_main(%{github: true, gh: ok, root: dir})

      dir2 = tmp_dir("gh2")

      unprotected =
        fake_gh(dir2, ~s(echo '{"message":"Branch not protected","status":"404"}' >&2\nexit 1))

      assert {:fail, ev} = Supply.protected_main(%{github: true, gh: unprotected, root: dir2})
      assert ev =~ "not protected"

      dir3 = tmp_dir("gh3")
      broken = fake_gh(dir3, "echo 'auth required' >&2\nexit 4")
      assert {:unverified, _} = Supply.protected_main(%{github: true, gh: broken, root: dir3})
    end

    test "signed tag: lightweight tag on HEAD fails, no tag fails" do
      repo = git_repo("tags")
      assert {:fail, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "no tag"
      git!(repo, ["tag", "v1"])
      assert {:fail, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "annotated"
    end

    test "signed tag: an ssh-signed annotated tag verifies and passes" do
      repo = git_repo("signed")
      key = Path.join(repo, "..") |> Path.expand() |> Path.join("sa2a_key_#{uniq()}")
      on_exit(fn -> File.rm_rf!(key) && File.rm_rf!(key <> ".pub") end)
      {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
      pub = File.read!(key <> ".pub") |> String.trim()
      signers = key <> ".signers"
      on_exit(fn -> File.rm(signers) end)
      File.write!(signers, "t@example.com " <> pub <> "\n")

      git!(repo, ["config", "gpg.format", "ssh"])
      git!(repo, ["config", "user.signingkey", key <> ".pub"])
      git!(repo, ["config", "gpg.ssh.allowedSignersFile", signers])
      git!(repo, ["tag", "-s", "v2", "-m", "release"])

      assert {:pass, ev} = Supply.signed_tag(%{github: true, root: repo})
      assert ev =~ "v2"
    end

    test "single release workflow: exactly one release-triggered workflow passes" do
      root = tmp_dir("wf1")
      wf = Path.join(root, ".github/workflows")
      File.mkdir_p!(wf)

      File.write!(Path.join(wf, "release.yml"), """
      name: release
      on:
        push:
          tags: ["v*"]
      jobs: {}
      """)

      File.write!(Path.join(wf, "ci.yml"), """
      name: ci
      on:
        push:
          branches: [main]
      jobs: {}
      """)

      assert {:pass, ev} = Supply.single_release_workflow(%{github: true, root: root})
      assert ev =~ "release.yml"

      File.write!(Path.join(wf, "release2.yml"), """
      name: release2
      on:
        release:
          types: [published]
      jobs: {}
      """)

      assert {:fail, ev} = Supply.single_release_workflow(%{github: true, root: root})
      assert ev =~ "release2.yml"
    end

    test "no release workflow fails" do
      root = tmp_dir("wf0")
      File.mkdir_p!(Path.join(root, ".github/workflows"))
      assert {:fail, _} = Supply.single_release_workflow(%{github: true, root: root})
    end
  end

  # ---------------------------------------------------- claims (the gate)

  describe "Claim grammar" do
    test "the claim line follows RFC-007 section 4" do
      line =
        Claim.statement(
          :c1,
          %{version: "v26.9.29", tier: "I1", scope: "same-host-os-user"},
          "a" |> String.duplicate(40)
        )

      assert line ==
               "SA2A v26.9.29 conforms to profile C1 at independence tier I1, hosting scope same-host-os-user, on subject SHA #{String.duplicate("a", 40)}"
    end
  end

  describe "CURRENT TREE STATUS (coordinator: update as lanes land)" do
    test "CURRENT_TREE c1 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c1, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert report.failing != []
    end

    test "CURRENT_TREE c2 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c2, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C2"
      ids = Enum.map(report.failing, & &1.id)
      # The authority_service/ and actuator/ projects have landed; C2 stays
      # withdrawn on the C1 prerequisites the dev/test profile cannot satisfy.
      assert "c1.security_profile_strict" in ids
      assert "c1.durable_claim_store" in ids
      assert "c1.keyed_journal" in ids
    end

    test "CURRENT_TREE c3 is NOT CONFORMANT" do
      report = Profiles.evaluate(:c3, %{})
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C3"
      ids = Enum.map(report.failing, & &1.id)
      # signer-set quorum landed (custodian-distinct); C3 is withdrawn on the
      # C1/C2 prerequisites that remain unmet in this tree.
      refute "c3.signer_set_quorum" in ids
      assert "c1.security_profile_strict" in ids
      assert "c1.durable_claim_store" in ids
    end

    test "supply-chain checks are :unverified without --github and block c2/c3" do
      report = Profiles.evaluate(:c2, %{})
      sup = Enum.filter(report.checks, &String.starts_with?(&1.id, "supply."))
      assert sup != []
      assert Enum.all?(sup, &(&1.status == :unverified))
      assert Enum.all?(sup, &(&1.id in Enum.map(report.unverified, fn c -> c.id end)))
    end
  end

  describe "the gate: all-pass fixture context earns the claim, one break withdraws it" do
    defp c1_context(overrides \\ %{}) do
      repo = git_repo("gate")
      {strict, _} = fixture_module("def current, do: :strict")
      {clean, _} = fixture_module("def report, do: %{violating_edges: []}")
      {bus, bus_bin} = fixture_module("def go(a), do: {:ok, a}")
      {canon, canon_bin} = fixture_module("def d(t), do: AshA2A.Identity.Canonical.digest(t)")

      {store, _} =
        fixture_module("""
        def durable?, do: true
        def claim(_d, _g), do: :ok
        def complete(_d, _r), do: :ok
        """)

      dir = Path.join(File.cwd!(), "tmp/conf_gate_#{uniq()}")
      on_exit(fn -> File.rm_rf!(dir) end)

      Map.merge(
        %{
          root: repo,
          security_profile_module: strict,
          closure_module: clean,
          command_bus: bus,
          boundary_modules: [canon],
          beam_binaries: %{bus => bus_bin, canon => canon_bin},
          claim_store: store,
          journal_dir: dir,
          journal_key_provider: keyed(:crypto.strong_rand_bytes(32))
        },
        overrides
      )
    end

    test "C1 with every dependency satisfied by real fixtures is CONFORMANT" do
      ctx = c1_context()
      report = Profiles.evaluate(:c1, ctx)
      assert report.failing == [], inspect(report.failing)
      assert report.unverified == []
      assert report.conformant?

      assert report.claim ==
               "SA2A v26.9.29 conforms to profile C1 at independence tier I1, hosting scope same-host-os-user, on subject SHA #{report.subject_sha}"
    end

    test "reverting one guard (Memory claim store) withdraws the claim" do
      ctx = c1_context(%{claim_store: AshA2A.C2.MemoryClaimStore})
      report = Profiles.evaluate(:c1, ctx)
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert "c1.durable_claim_store" in Enum.map(report.failing, & &1.id)
    end

    test ":dev_bypass forces NOT CONFORMANT even when every other check passes" do
      {bypass, _} = fixture_module("def current, do: :dev_bypass")
      report = Profiles.evaluate(:c1, c1_context(%{security_profile_module: bypass}))
      refute report.conformant?
      assert report.claim =~ "NOT CONFORMANT to C1"
      assert report.claim =~ "dev_bypass"
    end

    test ":legacy_compat forces NOT CONFORMANT even on c0" do
      {legacy, _} = fixture_module("def current, do: :legacy_compat")
      repo = git_repo("legacyc0")
      report = Profiles.evaluate(:c0, %{root: repo, security_profile_module: legacy})
      refute report.conformant?
      assert report.claim =~ "legacy_compat"
    end

    test "C0 alone is conformant on a clean fixture checkout with a strict/absent-neutral profile" do
      repo = git_repo("c0ok")
      {strict, _} = fixture_module("def current, do: :strict")
      report = Profiles.evaluate(:c0, %{root: repo, security_profile_module: strict})
      assert report.conformant?, inspect(report.failing)
    end

    test "a declared tier above I1 at C1 is :unverified evidence, not a claim" do
      report = Profiles.evaluate(:c1, c1_context(%{tier: "I2"}))
      refute report.conformant?
      assert "claim.tier_supported" in Enum.map(report.unverified, & &1.id)
    end

    test "a declared scope beyond same-host-os-user needs deployment evidence" do
      report = Profiles.evaluate(:c1, c1_context(%{scope: "physical-host"}))
      refute report.conformant?
      assert "claim.scope_supported" in Enum.map(report.unverified, & &1.id)
    end

    test "JSON projection carries subject, profile, status and every check" do
      report = Profiles.evaluate(:c1, c1_context())
      json = report |> Profiles.to_json_map() |> Jason.encode!() |> Jason.decode!()
      assert json["profile"] == "c1"
      assert json["conformant"] == true
      assert json["subject_sha"] == report.subject_sha
      assert length(json["checks"]) == length(report.checks)
      assert Enum.all?(json["checks"], &(&1["status"] in ["pass", "fail", "unverified"]))
    end
  end

  # ------------------------------------------------------------ mix task

  describe "mix task" do
    test "--profile with --json writes the machine report and raises when NOT CONFORMANT" do
      out = Path.join(tmp_dir("json"), "r.json")

      assert_raise Mix.Error, ~r/NOT CONFORMANT to C1/, fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c1", "--json", out])
      end

      json = out |> File.read!() |> Jason.decode!()
      assert json["profile"] == "c1"
      assert json["conformant"] == false
    end

    test "--profile with --report never raises" do
      out = Path.join(tmp_dir("json2"), "r.json")

      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c3", "--report", "--json", out])
      end)

      assert File.exists?(out)
    end

    test "unknown --profile is rejected" do
      assert_raise Mix.Error, ~r/unknown --profile/, fn ->
        Mix.Tasks.AshA2a.VerifyConformance.run(["--profile", "c9"])
      end
    end
  end
end

# --- SECTION 21: Original test/attestation/attestation_gate_test.exs ---
defmodule AshA2A.Attestation.GateTest do
  @moduledoc """
  Chicago-style tests: real :crypto ECDSA P-256 sign/verify round-trips, no
  mocks. Asserts on final typed outcomes (tokens, {:refused, reason}).
  """
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, Key}

  @now 1_700_000_000

  defp fresh_claims(nonce, extra) do
    Map.merge(
      %{
        "nonce" => nonce,
        "device_id" => "device-abc",
        "os_fingerprint" => "google/raven/raven:13/TQ3A.230901.001",
        "is_virtual" => false,
        "issued_at" => @now - 10
      },
      extra
    )
  end

  defp signed(extra \\ %{}, nonce \\ "nonce-123") do
    key = Key.generate()
    token = Key.sign(fresh_claims(nonce, extra), key)
    {key, token}
  end

  describe "Key sign/verify round-trip" do
    test "sign then verify with the matching public key returns the claims" do
      key = Key.generate()
      claims = %{"nonce" => "n1", "device_id" => "d1"}
      token = Key.sign(claims, key)
      assert {:ok, ^claims} = Key.verify(token, key)
    end

    test "tampered payload is refused with :bad_signature" do
      key = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, key)
      [pfx, payload, sig] = String.split(token, ".", parts: 3)

      # Tamper the payload (flip a byte of the JSON by re-encoding altered claims)
      forged_payload =
        payload
        |> then(fn p -> Base.url_decode64!(p, padding: false) end)
        |> String.replace("n1", "n2")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, sig], ".")
      assert {:error, :bad_signature} = Key.verify(tampered, key)
    end

    test "signature from a different key is refused" do
      k1 = Key.generate()
      k2 = Key.generate()
      token = Key.sign(%{"nonce" => "n1"}, k1)
      assert {:error, :bad_signature} = Key.verify(token, k2)
    end

    test "malformed token is typed-refused" do
      key = Key.generate()
      assert {:error, :malformed_token} = Key.verify("not-a-token", key)
    end
  end

  describe "verify_enclave/2" do
    test "fresh, real-shaped payload passes" do
      {key, token} = signed()

      assert {:ok, %{"device_id" => "device-abc"}} =
               Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "virtual claim triggers {:refused, :emulator_detected}" do
      {key, token} = signed(%{"is_virtual" => true})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "emulator-flavored os_fingerprint triggers :emulator_detected" do
      {key, token} = signed(%{"os_fingerprint" => "google/sdk_gphone_x86/generic:13"})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "known emulator package triggers :emulator_detected" do
      {key, token} = signed(%{"installed_packages" => ["com.bluestacks.something"]})
      assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "nonce-123"}, key: key)
    end

    test "tampered token is refused with :bad_signature" do
      {key, token} = signed()
      [pfx, payload, _sig] = String.split(token, ".", parts: 3)

      forged_payload =
        Base.url_decode64!(payload, padding: false)
        |> String.replace("\"device-abc\"", "\"device-hax\"")
        |> Base.url_encode64(padding: false)

      tampered = Enum.join([pfx, forged_payload, "AAAA"], ".")
      assert {:refused, :bad_signature} = Gate.verify_enclave({tampered, "nonce-123"}, key: key)
    end

    test "nonce mismatch is typed-refused" do
      {key, token} = signed()
      assert {:refused, :nonce_mismatch} = Gate.verify_enclave({token, "other-nonce"}, key: key)
    end
  end

  describe "verify_freshness/2" do
    test "fresh claim passes" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 30}, now: @now)
    end

    test "stale claim is refused" do
      assert {:refused, :stale} = Gate.verify_freshness(%{"issued_at" => @now - 91}, now: @now)
    end

    test "boundary: exactly max_staleness_sec old passes, +1s refuses" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now - 90}, now: @now)

      assert {:refused, :stale} =
               Gate.verify_freshness(%{"issued_at" => @now - 91},
                 now: @now,
                 max_staleness_sec: 90
               )
    end

    test "missing issued_at is malformed" do
      assert {:refused, :malformed_token} = Gate.verify_freshness(%{}, now: @now)
    end

    test "future-issued beyond small skew is refused :clock_skew (typed, not :stale)" do
      assert {:refused, :clock_skew} =
               Gate.verify_freshness(%{"issued_at" => @now + 60}, now: @now)
    end

    test "boundary: exactly 5s forward skew accepted, +1s refused" do
      assert :ok = Gate.verify_freshness(%{"issued_at" => @now + 5}, now: @now)

      assert {:refused, :clock_skew} =
               Gate.verify_freshness(%{"issued_at" => @now + 6}, now: @now)
    end
  end

  describe "verify_sensor_metadata/2" do
    defp good_sensor do
      %{
        "camera_make" => "Apple",
        "camera_model" => "iPhone 15 Pro",
        "gps" => %{"lat" => 35.68, "lon" => 139.76, "timestamp" => @now - 20, "accuracy" => 8.0}
      }
    end

    test "well-formed fresh sensor metadata passes" do
      assert :ok = Gate.verify_sensor_metadata(good_sensor(), now: @now)
    end

    test "missing camera_make is spoofed_payload" do
      claims = Map.delete(good_sensor(), "camera_make")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "missing gps block is spoofed_payload" do
      claims = Map.delete(good_sensor(), "gps")
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "absurd gps accuracy is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "accuracy"], 5_000_000.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "out-of-range lat is spoofed_payload" do
      claims = put_in(good_sensor(), ["gps", "lat"], 123.0)
      assert {:refused, :spoofed_payload} = Gate.verify_sensor_metadata(claims, now: @now)
    end

    test "stale gps timestamp is refused :stale" do
      claims = put_in(good_sensor(), ["gps", "timestamp"], @now - 300)
      assert {:refused, :stale} = Gate.verify_sensor_metadata(claims, now: @now)
    end
  end

  describe "verify_gps_trajectory/1 (mock-GPS rejection)" do
    defp obs(lat, lon, ts), do: %{"lat" => lat, "lon" => lon, "timestamp" => ts}

    test "realistic walk passes" do
      # Tokyo station -> ~200m away, 30s later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6830, 139.7690, @now + 30)
               ])
    end

    test "teleport Tokyo->Sapporo within 60s is :gps_impossible_jump" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 45)
               ])
    end

    test "sub-threshold jump Tokyo->Osaka (~392km < 500km) is allowed" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(34.6937, 135.5023, @now + 45)
               ])
    end

    test "large jump with >60s elapsed is allowed (flight-speed travel)" do
      # Same Tokyo->Sapporo jump but 2 hours later
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(43.0618, 141.3545, @now + 7200)
               ])
    end

    test "unsorted observations are sorted before checking" do
      assert {:refused, :gps_impossible_jump} =
               Gate.verify_gps_trajectory([
                 obs(43.0618, 141.3545, @now + 45),
                 obs(35.6812, 139.7671, @now)
               ])
    end

    test "identical-coordinate no-movement sequence is lawful (replay closed by nonce ledger, not geometry)" do
      assert :ok =
               Gate.verify_gps_trajectory([
                 obs(35.6812, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    # Platform law (OTP 28): NaN floats are unconstructible — float bit-pattern
    # matches, :math domain errors (sqrt(-1), log(0)), arithmetic overflow, and
    # binary_to_term NEW_FLOAT_EXT all raise. The substrate itself refuses NaN,
    # so the reachable form of this attack here is the adversarially huge
    # integer below (which would crash :math on unguarded code paths).
    test "sqrt(-1) raises badarg (platform law: :math never returns NaN)" do
      assert_raise ArithmeticError, fn -> :math.sqrt(-1.0) end
    end

    test "adversarially huge integer coordinate is refused :spoofed_payload (no :math badarg crash)" do
      huge = String.duplicate("9", 400) |> String.to_integer()

      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs(huge, 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end

    test "non-numeric coordinate string is refused :spoofed_payload" do
      assert {:refused, :spoofed_payload} =
               Gate.verify_gps_trajectory([
                 obs("35.6812", 139.7671, @now),
                 obs(35.6812, 139.7671, @now + 30)
               ])
    end
  end

  # ECDSA malleability: (r, s) and (r, n - s) both verify against the same
  # pubkey; the low-s gate must refuse the malleated twin before crypto.
  describe "signature malleability (canonical low-s)" do
    @n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    test "canonical token verifies" do
      {key, token} = signed()
      assert {:ok, _} = Key.verify(token, key)
    end

    test "malleated twin (s' = n - s) is refused :non_canonical_signature" do
      {key, token} = signed()
      twin = malleate(token)

      # the twin differs from the original but is still a valid ECDSA signature
      assert twin != token
      assert {:error, :non_canonical_signature} = Key.verify(twin, key)
    end

    test "malleated twin through verify_enclave is {:refused, :non_canonical_signature}" do
      {key, token} = signed()

      assert {:refused, :non_canonical_signature} =
               Gate.verify_enclave({malleate(token), "nonce-123"}, key: key)
    end

    defp malleate(token) do
      [pfx, payload, sig] = String.split(token, ".", parts: 3)
      der = Base.url_decode64!(sig, padding: false)
      <<0x30, _len, body::binary>> = der
      <<0x02, rlen, r::binary-size(rlen), 0x02, slen, s_bin::binary-size(slen)>> = body

      s = :binary.decode_unsigned(s_bin)
      s2_bin = der_int(@n - s)
      body2 = <<0x02, byte_size(r), r::binary, 0x02, byte_size(s2_bin), s2_bin::binary>>
      der2 = <<0x30, byte_size(body2), body2::binary>>

      Enum.join([pfx, payload, Base.url_encode64(der2, padding: false)], ".")
    end

    defp der_int(v) do
      bin = :binary.encode_unsigned(v)

      case bin do
        <<first, _::binary>> when first >= 128 -> <<0, bin::binary>>
        <<0, _::binary>> = padded -> padded
        _ -> bin
      end
    end
  end
end

# --- SECTION 22: Original test/attestation/gate_grant_allowlist_test.exs ---
defmodule AshA2A.Attestation.GateGrantAllowlistTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.Gate

  # Hand-pinned from /Users/sac/xaas/lib/xaas/governance/approval_geofence_exception_grant.ex
  # attributes (id/org_id/identifier_or_cidr/ttl_hours); approved_at + area are the
  # enforcement-side projections recorded at approve time (see GateGrantAllowlist moduledoc).
  @now 1_700_000_000

  defp grant(overrides \\ []) do
    {area_overrides, top} = Keyword.split(overrides, [:area])

    Map.merge(
      %{
        grant_id: "g-1",
        org_id: "org-1",
        identifier_or_cidr: "203.0.113.0/24",
        ttl_hours: 24,
        approved_at: @now - 60,
        area:
          Map.merge(
            %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0},
            case area_overrides[:area] do
              nil -> %{}
              %{} = m -> m
              kw -> Map.new(kw, fn {k, v} -> {Atom.to_string(k), v} end)
            end
          )
      },
      Map.new(top)
    )
  end

  # ~1255 km apart in under 60s — an impossible jump unless granted.
  defp jumping_obs do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "approved in-scope grant overrides the jump; same coordinates without/expired/out-of-scope still refuse" do
    assert Gate.verify_gps_trajectory(jumping_obs()) == {:refused, :gps_impossible_jump}

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant()]
           ) == :ok

    unapproved_area =
      grant(area: %{"lat" => 35.0, "lon" => 139.0, "radius_km" => 10.0})

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [unapproved_area]
           ) == {:refused, :gps_impossible_jump}

    expired = grant(approved_at: @now - 24 * 3600 - 1)

    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [expired]
           ) == {:refused, :gps_impossible_jump}
  end

  test "no grants supplied: /2 is outcome-identical to /1, and non-jump refusals are never overridden" do
    assert Gate.verify_gps_trajectory(jumping_obs(), now: @now) ==
             Gate.verify_gps_trajectory(jumping_obs())

    malformed = [%{"lat" => "x", "lon" => 0.0, "timestamp" => 1}]

    assert Gate.verify_gps_trajectory(malformed,
             now: @now,
             approved_grants: [grant()]
           ) == {:refused, :spoofed_payload}
  end

  test "mutation probe: grant cover is computed on real distances, not constant-true" do
    assert Gate.verify_gps_trajectory(jumping_obs(),
             now: @now,
             approved_grants: [grant(area: [radius_km: 0.0])]
           ) == {:refused, :gps_impossible_jump}
  end
end

# --- SECTION 23: Original test/attestation/lane01_hardening_test.exs ---
defmodule AshA2A.Attestation.Lane01HardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Attestation.{Gate, GateGrantAllowlist, Key}

  @now 1_700_000_000

  defp b64(d), do: Base.url_encode64(d, padding: false)

  defp signed_raw(raw_payload, key) do
    sig = :crypto.sign(:ecdsa, :sha256, raw_payload, [key.priv, :prime256v1])
    "v1." <> b64(raw_payload) <> "." <> b64(sig)
  end

  test "bad base64 token yields typed :malformed_token" do
    key = Key.generate()
    assert {:error, :malformed_token} = Key.verify("v1.!!!.@@@", key)
    assert {:refused, :malformed_token} = Gate.verify_enclave({"v1.!!!.@@@", "n"}, key)
  end

  test "non-JSON and non-map signed payloads yield typed errors" do
    key = Key.generate()
    # Retry until the random signature is low-s (verify enforces canonical form).
    non_json = find_canonical("not json at all", key)
    assert {:error, :malformed_token} = Key.verify(non_json, key)
    list_payload = find_canonical("[1,2,3]", key)
    assert {:error, :malformed_token} = Key.verify(list_payload, key)
  end

  defp find_canonical(raw, key) do
    Enum.find_value(1..64, fn _ ->
      tok = signed_raw(raw, key)

      case Key.verify(tok, key) do
        {:error, :non_canonical_signature} -> nil
        _ -> tok
      end
    end)
  end

  test "bad private key is {:error, :bad_key}; verify without :pub or non-binary token is typed" do
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{priv: :nope, pub: "x"})
    assert {:error, :bad_key} = Key.sign(%{"a" => 1}, %{})
    assert {:error, :malformed_token} = Key.verify("v1.a.b", %{})
    assert {:error, :malformed_token} = Key.verify(nil, Key.generate())
    assert {:refused, :malformed_token} = Gate.verify_enclave({nil, "n"}, nil)
  end

  test "emulator detection type guards refuse non-binary fingerprint / non-list packages" do
    key = Key.generate()

    for extra <- [%{"os_fingerprint" => 42}, %{"installed_packages" => "com.bluestacks"}] do
      token = Key.sign(Map.merge(%{"nonce" => "n"}, extra), key)
      assert {:refused, :spoofed_payload} = Gate.verify_enclave({token, "n"}, key)
    end

    token = Key.sign(%{"nonce" => "n", "installed_packages" => ["com.android.fly.x"]}, key)
    assert {:refused, :emulator_detected} = Gate.verify_enclave({token, "n"}, key)
  end

  defp grant(extra \\ %{}) do
    Map.merge(
      %{
        grant_id: "g",
        org_id: "org-1",
        identifier_or_cidr: "id-1",
        ttl_hours: 24,
        approved_at: @now - 60,
        area: %{"lat" => 37.0, "lon" => -122.0, "radius_km" => 2000.0}
      },
      extra
    )
  end

  defp jumping do
    [
      %{"lat" => 37.0, "lon" => -122.0, "timestamp" => @now - 30},
      %{"lat" => 47.0, "lon" => -115.0, "timestamp" => @now}
    ]
  end

  test "grant missing :area is not covering; no crash" do
    g = Map.delete(grant(), :area)

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "unsorted observations are sorted like the base check" do
    assert :ok =
             Gate.verify_gps_trajectory(Enum.reverse(jumping()),
               approved_grants: [grant()],
               now: @now
             )
  end

  test "future approved_at grant is rejected" do
    g = grant(%{approved_at: @now + 1000})

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [g], now: @now)
  end

  test "grants are scoped by org_id / identifier when supplied" do
    assert :ok =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               org_id: "org-1"
             )

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               org_id: "org-2"
             )

    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(),
               approved_grants: [grant()],
               now: @now,
               identifier: "other"
             )

    assert :ok = GateGrantAllowlist.override?(jumping(), [grant()], @now, identifier: "id-1")
  end

  test "malformed grant entries are ignored" do
    assert {:refused, :gps_impossible_jump} =
             Gate.verify_gps_trajectory(jumping(), approved_grants: [:junk, %{}, nil], now: @now)
  end
end
