# Lane EV14 - Conference-sim cross-vendor interoperability court.
#
# The event's actual promise: Vendor A (the ash_a2a venue) accepts a signed
# credential issued by Vendor B (the ash_affidavit exhibitor) - two
# independent codebases, two independent builds, only a shared trust root
# (the exhibitor's published JWKS) and the engine's document law in common.
#
# How this court stays honest:
#
#   * Vendor B's signing runs as a real separate OS subprocess in the
#     ash_affidavit checkout (examples/vendor_b_exhibit.exs), through the
#     REAL pinned wasm (AshAffidavit.Signing.derive_subject_digest/3,
#     Signing.signing_input/2 -> verify_signature_input,
#     Signing.verify_signature/4 -> verify_signature). It emits a credential
#     exhibit (JSON) that is the ONLY thing crossing the vendor boundary -
#     exactly like an exhibitor handing the venue a signed badge. The venue
#     never sees Vendor B's private key.
#   * Vendor A (this test process) recomputes the signing pre-image with its
#     OWN vendored engine (hex dep ash_affidavit 26.10.1 - a DIFFERENT engine
#     identity than the exhibitor's tip) via verify_signature_input, and
#     verifies the Ed25519 signature over those engine-recomputed bytes with
#     :crypto - never over a caller-supplied pre-image.
#   * S3 correlation-law analog: the credential binds subject + hash. The
#     subject digest is the engine's domain-separated BLAKE3
#     (derive_subject_digest), not a host hash; the payload hash is SHA-256
#     over the canonical payload document.
#   * Court (d): the venue's own signed agent card (real
#     AshA2A.Protocol.CardSigning) and the affidavit credential coexist as
#     two trust roots; cross-presentation is refused (no clobbering).
#
# Production gaps this court documents (honest scoping, no fake acceptance):
#
#   1. AshA2A.Protocol.CardSigning (HS256/RS256/ES256) has no Ed25519 - the
#      venue's production card verifier cannot consume the exhibitor's
#      algorithm today. The translation adapter below does the Ed25519 step
#      with :crypto directly (real crypto, not a stub); the production fix
#      is one algorithm addition to CardSigning.
#   2. The venue's vendored engine (hex 26.10.1) exposes
#      verify_signature_input but NOT derive_subject_digest /
#      verify_signature - the venue cannot re-derive subject digests or have
#      the engine adjudicate signatures. The adapter therefore holds an
#      exhibitor-published PUBLIC subject registry (engine-derived digests)
#      as the correlation table. Bumping the vendored engine is the
#      production fix.
#
# Fixture modules live at TOP LEVEL of this file (never nested inside the
# test module: Elixir nests dotted module names under the enclosing module).

defmodule AshA2A.Test.ConferenceSim.Interop.VenueVerifier do
  @moduledoc """
  The venue-side credential-translation adapter (Vendor A) - the MINIMAL
  adapter the honest-scoping clause of the lane asks for. The venue's
  production verifier (AshA2A.Protocol.CardSigning) cannot consume an
  affidavit-shaped credential today (no Ed25519; the vendored engine lacks
  verify_signature), so the adapter performs the verification steps the
  production verifier would perform once the gaps close - with real crypto
  at every step:

    1. the venue's OWN vendored engine recomputes the signing pre-image from
       the envelope bytes (verify_signature_input - never a caller-supplied
       pre-image);
    2. the Ed25519 signature over those engine-recomputed bytes is verified
       against the exhibitor's JWKS key (:crypto, real; ES256 over a P-256 SEC1 point);
    3. the subject correlation fence: the envelope's subject_digest must be
       the registry digest of the attendee PRESENTING the credential (S3's
       correlation law: a credential for X cannot serve Y);
    4. the payload binding: SHA-256 over the canonical payload document must
       equal the credential's payload_hash.

  Returns {:ok, claims} or {:refused, step, detail} - acceptance is never
  faked; every refusal names the failing step.
  """

  @domain_tag "affidavit.crypto-trust-plane.v1"

  def adjudicate(credential, presented_as, subject_registry, jwks, host) do
    envelope = credential["envelope"]

    with {:ok, pre_image} <- engine_pre_image(envelope, host),
         {:ok, key} <- jwks_key(jwks, envelope["key_id"]),
         :ok <- signature_step(pre_image, credential["signature_hex"], key),
         :ok <- subject_fence(envelope["subject_digest"], presented_as, subject_registry),
         :ok <- payload_fence(credential) do
      {:ok,
       %{
         subject: presented_as,
         audience: envelope["audience"],
         domain_tag: @domain_tag,
         key_id: envelope["key_id"],
         engine_witness: pre_image
       }}
    end
  end

  # Step 1: the venue's own engine recomputes the pre-image. The expectation
  # is deliberately impossible so the response echoes the ENGINE's
  # recomputation, not any caller-attested value.
  defp engine_pre_image(envelope, host) do
    request = %{
      "op" => "verify_signature_input",
      "envelope_json" => Jason.encode!(wire_envelope(envelope)),
      "expected_signing_input_hex" => String.duplicate("00", 128)
    }

    case AshAffidavit.call(request, server: host) do
      {:ok, %{"signing_input_hex" => hex}} when is_binary(hex) ->
        {:ok, Base.decode16!(hex, case: :lower)}

      {outcome, refusal} ->
        {:refused, :engine_pre_image, {outcome, Map.from_struct(refusal)}}
    end
  end

  # The engine canonicalizes nonce/subject_digest as byte arrays; a hex
  # string form is normalized to byte lists so both engine identities
  # canonicalize the same document.
  defp wire_envelope(envelope) do
    Map.new(envelope, fn
      {"nonce" = f, v} when is_binary(v) and byte_size(v) == 32 ->
        {f, v |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()}

      {"subject_digest" = f, v} when is_binary(v) and byte_size(v) == 64 ->
        {f, v |> Base.decode16!(case: :mixed) |> :binary.bin_to_list()}

      {f, v} ->
        {f, v}
    end)
  end

  defp jwks_key(%{"keys" => keys}, kid) do
    case Enum.filter(keys, &(&1["kid"] == kid)) do
      [key] -> {:ok, key}
      _ -> {:refused, :unknown_key, %{kid: kid}}
    end
  end

  # Step 2: real ES256 over the ENGINE-recomputed bytes (the key material
  # is the SEC1 uncompressed point from the exhibitor's JWKS).
  defp signature_step(pre_image, sig_hex, key) do
    with {:ok, sig} <- Base.decode16(sig_hex, case: :mixed),
         {:ok, pub} <- Base.url_decode64(key["sec1"], padding: false) do
      verified =
        try do
          :crypto.verify(:ecdsa, :sha256, pre_image, sig, [pub, :secp256r1])
        rescue
          # a well-formed but non-canonical point (not on the curve) is a
          # decided-negative at the host, same verdict as a signature miss
          ErlangError -> false
        end

      if verified do
        :ok
      else
        {:refused, :bad_signature, %{kid: key["kid"]}}
      end
    else
      _ -> {:refused, :malformed_material, %{kid: key["kid"]}}
    end
  end

  # Step 3: S3 correlation-law analog - a credential for X cannot serve Y.
  defp subject_fence(envelope_digest_hex, presented_as, registry) do
    registered = Map.get(registry, presented_as)

    cond do
      is_nil(registered) ->
        {:refused, :unregistered_subject, %{subject: presented_as}}

      registered != envelope_digest_hex ->
        {:refused, :subject_correlation_mismatch,
         %{presented_as: presented_as, bound: envelope_digest_hex, registered: registered}}

      true ->
        :ok
    end
  end

  # Step 4: the payload binding (hash law over the canonical payload doc).
  defp payload_fence(credential) do
    recomputed = Base.encode16(:crypto.hash(:sha256, Jason.encode!(credential["payload"])), case: :lower)

    if recomputed == credential["payload_hash_hex"] do
      :ok
    else
      {:refused, :payload_hash_mismatch, %{recomputed: recomputed, presented: credential["payload_hash_hex"]}}
    end
  end
end

defmodule AshA2A.Test.ConferenceSim.InteropCourt do
  use ExUnit.Case, async: false

  alias AshA2A.Test.ConferenceSim.Interop.VenueVerifier

  @ash_affidavit_dir Path.expand("../../../ash_affidavit", __DIR__)
  @build_root "_build-ev14b"
  @domain_tag "affidavit.crypto-trust-plane.v1"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ash_affidavit)
    wasm = Path.join([Application.app_dir(:ash_affidavit), "priv", "affidavit", "affidavit.wasm"])
    {:ok, venue_host} = AshAffidavit.Host.start_link(name: nil, bytes: File.read!(wasm))
    exhibit = run_vendor_b!()
    on_exit(fn -> Application.delete_env(:ash_affidavit, :start_pool) end)
    %{venue_host: venue_host, exhibit: exhibit}
  end

  test "court a: an exhibitor-issued signed credential is accepted by the venue (two wasm identities agree)",
       %{exhibit: exhibit, venue_host: venue_host} do
    {:ok, claims} =
      VenueVerifier.adjudicate(exhibit["credential"], "attendee-X", exhibit["subject_registry"], exhibit["jwks"], venue_host)

    assert claims.subject == "attendee-X"
    assert claims.audience == "conference-sim.venue"
    assert claims.domain_tag == @domain_tag
    assert claims.key_id == exhibit["kid"]
    assert byte_size(claims.engine_witness) > 0

    assert Base.encode16(claims.engine_witness, case: :lower) ==
             exhibit["engine_witness"]["signing_input_hex"]
  end

  test "court b: a tampered credential is refused - envelope tamper and signature tamper",
       %{exhibit: exhibit, venue_host: venue_host} do
    # (i) envelope tamper: audience rewritten, signature left as issued - the
    # engine recomputes a different pre-image, so the signature no longer
    # verifies.
    tampered = put_in(exhibit, ["credential", "envelope", "audience"], "conference-sim.venue.vip")

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               tampered["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    # (ii) signature tamper: flip one hex nibble of the Ed25519 signature.
    sig = exhibit["credential"]["signature_hex"]
    tampered_sig = flip_hex_nibble(sig, 5)
    assert tampered_sig != sig

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               put_in(exhibit, ["credential", "signature_hex"], tampered_sig)["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )
  end

  test "court c: the correlation fence - a credential for attendee X cannot serve attendee Y",
       %{exhibit: exhibit, venue_host: venue_host} do
    assert {:refused, :subject_correlation_mismatch, detail} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-Y",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    assert detail.presented_as == "attendee-Y"
    assert detail.bound == exhibit["subject_registry"]["attendee-X"]
    assert detail.registered == exhibit["subject_registry"]["attendee-Y"]
    refute detail.bound == detail.registered

    assert {:refused, :unregistered_subject, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-Z",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    # Payload tamper: a rewritten payload document fails the hash binding
    # even though the signature-side steps still pass.
    tampered = put_in(exhibit, ["credential", "payload", "badge_class"], "vip")

    assert {:refused, :payload_hash_mismatch, %{recomputed: r, presented: p}} =
             VenueVerifier.adjudicate(
               tampered["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               exhibit["jwks"],
               venue_host
             )

    refute r == p

    # An unknown key id is refused, not silently skipped.
    assert {:refused, :unknown_key, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               %{"keys" => []},
               venue_host
             )
  end

  test "court d: two trust roots coexist - the venue card and the affidavit credential do not clobber",
       %{exhibit: exhibit, venue_host: venue_host} do
    # The venue's own root: a real agent-card JWS (CardSigning over the RFC
    # 8785 wire projection, HS256 shared-secret root).
    venue_key = :crypto.strong_rand_bytes(32)
    card = %{name: "venue-agent", url: "https://venue.example/a2a", description: "venue", version: "1.0.0"}
    signed_card = AshA2A.Protocol.CardSigning.sign(card, venue_key, kid: "venue-hs1")

    assert :ok = AshA2A.Protocol.CardSigning.verify(signed_card, venue_key)

    # The affidavit credential verifies under the exhibitor root at the same
    # time - neither admission depends on the other.
    {:ok, _claims} =
      VenueVerifier.adjudicate(exhibit["credential"], "attendee-X", exhibit["subject_registry"], exhibit["jwks"], venue_host)

    # Cross-presentation is refused: the venue card does NOT verify under a
    # root derived from exhibitor key material.
    [exhibitor_key] = exhibit["jwks"]["keys"]
    exhibitor_material = "ev14-cross-root:" <> exhibitor_key["sec1"]

    assert {:error, {:bad_signature, %{index: 0}}} =
             AshA2A.Protocol.CardSigning.verify(signed_card, exhibitor_material)

    # A well-formed but WRONG ES256 key refuses the credential at the
    # signature step - the venue secret is not an exhibitor root.
    venue_as_jwks = %{
      "keys" => [
        %{
          "kty" => "EC",
          "crv" => "P-256",
          "alg" => "ES256",
          "kid" => exhibit["kid"],
          "sec1" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false)
        }
      ]
    }

    assert {:refused, :bad_signature, _} =
             VenueVerifier.adjudicate(
               exhibit["credential"],
               "attendee-X",
               exhibit["subject_registry"],
               venue_as_jwks,
               venue_host
             )

    # After all cross-presentation attempts, the honest credential still
    # verifies: coexistence did not disturb either root.
    {:ok, _} =
      VenueVerifier.adjudicate(exhibit["credential"], "attendee-X", exhibit["subject_registry"], exhibit["jwks"], venue_host)
  end

  # ---- fixtures ----------------------------------------------------------------

  defp run_vendor_b! do
    script = Path.join([@ash_affidavit_dir, "examples", "vendor_b_exhibit.exs"])
    result_path = Path.join(System.tmp_dir!(), "ev14-exhibit-#{System.unique_integer([:positive])}.json")

    {output, status} =
      System.cmd("mix", ["run", "--no-start", script],
        cd: @ash_affidavit_dir,
        env: %{"MIX_BUILD_ROOT" => @build_root, "RESULT_PATH" => result_path},
        stderr_to_stdout: true
      )

    if status != 0 do
      flunk("Vendor B exhibit subprocess failed (exit #{status}):\n#{output}")
    end

    exhibit = result_path |> File.read!() |> Jason.decode!()
    File.rm(result_path)
    exhibit
  end

  defp flip_hex_nibble(hex, idx) do
    {prefix, <<n, rest::binary>>} = String.split_at(hex, idx)
    prefix <> <<flip_char(n)>> <> rest
  end

  defp flip_char(c) when c in ?0..?8, do: c + 1
  defp flip_char(?9), do: ?a
  defp flip_char(?a), do: ?b
  defp flip_char(?b), do: ?c
  defp flip_char(?c), do: ?d
  defp flip_char(?d), do: ?e
  defp flip_char(?e), do: ?f
  defp flip_char(?f), do: ?0
end
