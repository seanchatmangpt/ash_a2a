# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.AffidavitOcel2CourtTest do
  @moduledoc """
  PRD v26.10.4 §4.6 "Affidavit Trust Plane & IEEE OCEL v2 Telemetry" (FR-06
  acceptance court, PRD §5 item 6): a Chicago
  court over the REAL Affidavit WASM engine (`AshAffidavit` on Wasmtime via
  `wasmex`, engine bytes at `deps/ash_affidavit/priv/affidavit/affidavit.wasm`)
  and the OCEL v2 ndjson projection (`AshA2A.Evidence.Ocel2`). Zero mocks.

  Witnessed, in order:

    1. **Byte-identical replay** — a receipt sealed over the lifecycle events
       replays to the identical `chain_hash`/`content_address` on re-assembly,
       and the JSON-serialized receipt re-verifies `accepted: true` at the same
       content address.
    2. **Tamper-evident chain** — flipping one byte inside one event's
       `payload_commitment` makes the engine's verify verdict `accepted: false`
       with a named failing stage, as a typed verdict map — never a crash.
    3. **OCEL v2 schema** — the receipt's ndjson projection parses line-by-line
       and validates against the OCEL v2 event/object structure, correlating
       `WorkOrder`, `Agent`, `EvidencePackage` and `Resource` objects; a
       corrupted stream is refused with a typed code (`:undeclared_object`,
       `:bad_json`, `:bad_field`), not a crash.
    4. **ML-DSA-65 (PQ-SEAL-v1) signature verification** — the real WASM
       `verify_signature_input` op recomputes the signing pre-image of the
       KAT vector `env-001-ML-DSA-65` (from the affidavit engine's own law
       crate, `affidavit-core::crypto_verify`) and binds it byte-for-byte;
       a one-byte-drift expectation is a typed `verified: false` mismatch.

  PQ-SEAL-v1 is the PRD's name (FR-06.2) for this receipt-sealing path:
  the affidavit engine's PQC-profile envelope (`algorithm: "ML_DSA65"`,
  `profile: "PQC"`) over the BLAKE3-chained `core/v1` receipt. Boundary,
  preserved from the engine's own trust-model note: `verify_signature_input`
  proves *which bytes must be signed* and that the presented expectation
  binds them — the EC/ML-DSA arithmetic itself lives in the external signer
  by design. This court witnesses the engine's real computation over the
  real KAT bytes; it never re-implements that arithmetic in the BEAM.

  Availability discipline: if the engine cannot run in-test, the courts
  refuse LOUDLY — `require_engine!/0` embeds the exact typed refusal in the
  failure — and the `@tag :wasm_unavailable` test below documents the typed
  unavailability surface explicitly. The engine is never silently skipped.
  """

  use ExUnit.Case, async: false

  alias AshA2A.Evidence.Affidavit
  alias AshA2A.Evidence.Ocel2

  # ---------------------------------------------------------------------------
  # KAT vector env-001-ML-DSA-65, copied verbatim from the engine's own law
  # crate (affidavit-core/src/crypto_verify.rs, test constants V1_CANONICAL /
  # V1_SIGNING_INPUT_HEX; rendered plane fixtures
  # crypto_trust_kat_vectors.json, surfaces.envelope[1]).
  # ---------------------------------------------------------------------------

  @mldsa65_canonical ~s({"algorithm":"ML_DSA65","audience":"affidavit.kat","expires_at":4102444800,"generation":1,"key_id":"afk1_932a436a743d67cd","nonce":[49,148,240,225,154,244,132,33,20,7,183,98,118,211,47,50],"not_before":1700000000,"policy_epoch":1,"profile":"PQC","revocation_epoch":0,"subject_digest":[18,60,249,28,128,193,211,38,120,198,222,80,164,85,43,52,17,76,4,173,228,175,245,220,104,114,253,206,55,248,114,68],"version":"CTP-ENVELOPE-v1"})

  @mldsa65_signing_input_hex "6166666964617669742e63727970746f2d74727573742d706c616e652e7631006166666964617669742e63727970746f2d74727573742d706c616e652e76310000000000000001ac7b22616c676f726974686d223a224d4c5f4453413635222c2261756469656e6365223a226166666964617669742e6b6174222c22657870697265735f6174223a343130323434343830302c2267656e65726174696f6e223a312c226b65795f6964223a2261666b315f39333261343336613734336436376364222c226e6f6e6365223a5b34392c3134382c3234302c3232352c3135342c3234342c3133322c33332c32302c372c3138332c39382c3131382c3231312c34372c35305d2c226e6f745f6265666f7265223a313730303030303030302c22706f6c6963795f65706f6368223a312c2270726f66696c65223a22505143222c227265766f636174696f6e5f65706f6368223a302c227375626a6563745f646967657374223a5b31382c36302c3234392c32382c3132382c3139332c3231312c33382c3132302c3139382c3232322c38302c3136342c38352c34332c35322c31372c37362c342c3137332c3232382c3137352c3234352c3232302c3130342c3131342c3235332c3230362c35352c3234382c3131342c36385d2c2276657273696f6e223a224354502d454e56454c4f50452d7631227d"

  # A fixed instant so the OCEL projection is byte-reproducible.
  @ocel_time ~U[2026-10-05 00:00:00Z]

  setup do
    # The real engine pool (Wasmtime via wasmex). Named globally; if another
    # test already started it, reuse it — never start a second.
    if is_nil(Process.whereis(AshAffidavit.Pool)) do
      case start_supervised({AshAffidavit.Pool, size: 1}) do
        {:ok, _pid} -> :ok
        # Raced with a concurrent starter: the global instance wins.
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Court 1 — byte-identical replay
  # ---------------------------------------------------------------------------

  test "court 1: sealed receipt replays byte-identically (chain_hash, content_address, re-verify)" do
    caps = require_engine!()
    assert caps["hash"] == "blake3"
    assert caps["format_version"] == "core/v1"

    events = lifecycle_events()

    assert {:ok, first} = Affidavit.assemble_receipt(events)
    assert {:ok, second} = Affidavit.assemble_receipt(events)

    # Deterministic sealing: same events, same chain, same content address.
    assert first["chain_hash"] == second["chain_hash"]
    assert first["content_address"] == second["content_address"]

    receipt = first["receipt"]
    assert receipt["format_version"] == "core/v1"
    assert is_binary(receipt["chain_hash"]) and byte_size(receipt["chain_hash"]) == 64

    # Serialize -> deserialize -> re-verify: identical digest, accepted verdict.
    serialized = Jason.encode!(receipt)
    assert decoded = Jason.decode!(serialized)
    assert decoded == receipt

    assert {:ok, %{"accepted" => true, "content_address" => replay_address}} =
             AshAffidavit.call(%{"op" => "verify", "receipt" => decoded})

    assert replay_address == first["content_address"]

    assert {:ok, true} = Affidavit.verify_receipt(decoded)
  end

  # ---------------------------------------------------------------------------
  # Court 2 — tamper-evident chain
  # ---------------------------------------------------------------------------

  test "court 2: one flipped byte in an event fails verification with a typed verdict, not a crash" do
    require_engine!()

    assert {:ok, assembled} = Affidavit.assemble_receipt(lifecycle_events())
    receipt = assembled["receipt"]

    tampered = flip_event_commitment_byte(receipt, 0)
    assert tampered != receipt

    # The engine answers with a structured verdict (accepted: false, named
    # failing stage, non-generic reason) — a typed refusal of the tampered
    # bytes, never a raise.
    assert {:ok, verdict} = AshAffidavit.call(%{"op" => "verify", "receipt" => tampered})
    assert verdict["accepted"] == false
    assert verdict["reason"] not in [nil, "all stages passed"]

    failed_stages =
      verdict["outcomes"]
      |> Enum.filter(&(&1["passed"] == false))
      |> Enum.map(& &1["stage"])

    assert failed_stages != []
    assert "chain_integrity" in failed_stages or "verify_commitments" in failed_stages

    # The original receipt still verifies clean after the tampered one.
    assert {:ok, true} = Affidavit.verify_receipt(receipt)
  end

  # ---------------------------------------------------------------------------
  # Court 3 — OCEL v2 ndjson schema over the sealed receipt
  # ---------------------------------------------------------------------------

  test "court 3: receipt projects to valid OCEL v2 ndjson correlating WorkOrder/Agent/EvidencePackage/Resource" do
    require_engine!()

    assert {:ok, assembled} = Affidavit.assemble_receipt(lifecycle_events())
    receipt = assembled["receipt"]

    assert {:ok, lines} = Ocel2.from_receipt(receipt, time: @ocel_time)
    assert {:ok, ndjson} = Ocel2.encode_ndjson(lines)
    assert is_binary(ndjson) and ndjson != ""

    # Round-trip: every ndjson line parses as one JSON object.
    assert {:ok, decoded_lines} = Ocel2.decode_ndjson(ndjson)
    assert length(decoded_lines) == length(lines)

    # OCEL v2 structure: event lines carry the five-key event shape, object
    # lines the timed-row attribute shape.
    assert {events, objects} = Enum.split_with(decoded_lines, &Map.has_key?(&1, "event_id"))

    assert Enum.all?(events, fn line ->
             match?(
               %{"event_type" => <<_::binary>>, "event_time" => <<_::binary>>, "attributes" => %{}, "relationships" => [_ | _]},
               line
             )
           end)

    assert Enum.all?(objects, fn line ->
             match?(%{"object_type" => <<_::binary>>, "attributes" => [_ | _]}, line) and
               Enum.all?(line["attributes"], &match?(%{"name" => _, "time" => _, "value" => _}, &1))
           end)

    # FR-06.3 correlation closure: all four object types declared, and every
    # relationship names a declared object of the same stream.
    observed_types = objects |> Enum.map(& &1["object_type"]) |> Enum.uniq() |> Enum.sort()
    assert observed_types == ~w(Agent EvidencePackage Resource WorkOrder)

    declared_ids = objects |> Enum.map(& &1["object_id"]) |> MapSet.new()

    for event <- events,
        relationship <- event["relationships"] do
      assert MapSet.member?(declared_ids, relationship["object_id"]),
             "relationship target #{inspect(relationship)} is not a declared object"
    end

    # The full validator agrees.
    assert :ok = Ocel2.validate(decoded_lines)

    # Each event line carries the commitment it was sealed with, so the stream
    # replays to the same receipt bytes.
    sealed_commitments =
      receipt["events"] |> Enum.map(& &1["payload_commitment"]) |> Enum.sort()

    stream_commitments =
      events |> Enum.map(& &1["attributes"]["payload_commitment"]) |> Enum.sort()

    assert stream_commitments == sealed_commitments
  end

  test "court 3b: corrupted streams are typed refusals, never crashes" do
    assert {:ok, assembled} = Affidavit.assemble_receipt(lifecycle_events())
    assert {:ok, lines} = Ocel2.from_receipt(assembled["receipt"], time: @ocel_time)
    assert {:ok, ndjson} = Ocel2.encode_ndjson(lines)

    # A relationship naming an object the stream never declares.
    {:ok, decoded_lines} = Ocel2.decode_ndjson(ndjson)

    dropped_object =
      Enum.reject(decoded_lines, &(&1["object_id"] == "wo-42" and Map.has_key?(&1, "object_type")))

    assert {:error, %{code: :undeclared_object}} = Ocel2.validate(dropped_object)

    # A non-JSON line.
    assert {:error, %{code: :bad_json}} = Ocel2.decode_ndjson(ndjson <> "{not json\n")

    # A corrupted event_time.
    corrupted_time =
      Enum.map(decoded_lines, fn
        line -> if Map.has_key?(line, "event_id"), do: %{line | "event_time" => "not-a-timestamp"}, else: line
      end)

    assert {:error, %{code: :bad_field}} = Ocel2.validate(corrupted_time)

    # An object type outside the FR-06.3 vocabulary.
    alien_type =
      Enum.map(decoded_lines, fn
        line -> if Map.has_key?(line, "object_id"), do: %{line | "object_type" => "Unicorn"}, else: line
      end)

    assert {:error, %{code: :unknown_object_type}} = Ocel2.validate(alien_type)
  end

  # ---------------------------------------------------------------------------
  # Court 4 — ML-DSA-65 (PQ-SEAL-v1) signature verification through real WASM
  # ---------------------------------------------------------------------------

  test "court 4: ML-DSA-65 envelope binding verifies through the real WASM engine (KAT env-001)" do
    caps = require_engine!()
    assert "verify_signature_input" in caps["ops"]

    # The KAT document is the PQC profile with the ML-DSA-65 algorithm — the
    # PQ-SEAL-v1 envelope PRD FR-06.2 names.
    assert String.contains?(@mldsa65_canonical, ~s("algorithm":"ML_DSA65"))
    assert String.contains?(@mldsa65_canonical, ~s("profile":"PQC"))

    request = %{
      "op" => "verify_signature_input",
      "envelope_json" => @mldsa65_canonical,
      "expected_signing_input_hex" => @mldsa65_signing_input_hex
    }

    assert {:ok, %{"verified" => true, "signing_input_hex" => computed, "canonical_bytes_len" => len}} =
             AshAffidavit.call(request)

    # The engine recomputes exactly the KAT pre-image, byte for byte.
    assert computed == @mldsa65_signing_input_hex
    assert len == byte_size(@mldsa65_canonical)

    # One nibble of drift in the expectation: a typed `verified: false`
    # mismatch — the binding check answers "no", it does not raise.
    tampered_request = %{request | "expected_signing_input_hex" => flip_last_hex_nibble(@mldsa65_signing_input_hex)}

    assert {:ok, %{"verified" => false, "signing_input_hex" => recomputed}} = AshAffidavit.call(tampered_request)
    assert recomputed == @mldsa65_signing_input_hex
  end

  # ---------------------------------------------------------------------------
  # Availability discipline — typed, never silent
  # ---------------------------------------------------------------------------

  @tag :wasm_unavailable
  test "engine unavailability is explicitly typed, with the exact refusal embedded" do
    case probe_engine() do
      {:ok, caps} ->
        # Real path witnessed on this runtime: the engine is available and
        # states its identity.
        assert caps["module"] == "affidavit-wasm"
        assert is_binary(caps["version"])
        assert "assemble" in caps["ops"] and "verify" in caps["ops"]

      {:unavailable, detail} ->
        # UNAVAILABLE-in-test: the exact typed load error is carried in the
        # detail, never swallowed. Assert the shape and re-embed it in the
        # failure so it lands in the court record either way.
        assert is_binary(detail) and detail != "",
               "WASM engine UNAVAILABLE-in-test: #{detail}"
    end
  end

  test "an unloadable engine is a typed refusal carrying the exact load error, never a crash" do
    # A Host pointed at bytes that do not exist starts fine (load failure is
    # deferred to call time, per the host contract) and answers every request
    # with a typed refusal.
    ref = make_ref()

    start_supervised!(
      {AshAffidavit.Host,
       name: ref,
       wasm_path: "/nonexistent/affidavit-unavailable-in-test.wasm",
       expected_sha256: :unpinned}
    )

    assert {:error, %AshAffidavit.Refusal{} = refusal} =
             AshAffidavit.Host.request(ref, %{"op" => "capabilities"})

    assert refusal.code in ~w(wasm_unreadable wasm_not_vendored wasm_invalid)a
    assert refusal.detail =~ "affidavit-unavailable-in-test.wasm"
  end

  # ---------------------------------------------------------------------------
  # Collaboration helpers (all real)
  # ---------------------------------------------------------------------------

  defp require_engine! do
    case probe_engine() do
      {:ok, caps} ->
        caps

      {:unavailable, detail} ->
        flunk(
          "WASM engine UNAVAILABLE-in-test (typed, never silently skipped): " <>
            detail <>
            " — courts 1/2/4 require the real Affidavit WASM engine " <>
            "(deps/ash_affidavit/priv/affidavit/affidavit.wasm on Wasmtime via wasmex)."
        )
    end
  end

  defp probe_engine do
    case AshAffidavit.call(%{"op" => "capabilities"}) do
      {:ok, caps} -> {:ok, caps}
      # {:refused | :trap | :unsupported, %AshAffidavit.Refusal{}} — the exact
      # typed refusal is embedded verbatim so the court record carries WHY.
      {tag, %AshAffidavit.Refusal{} = refusal} -> {:unavailable, "#{inspect(tag)} #{inspect(refusal)}"}
    end
  end

  # The lifecycle trace: a work order opened, an agent enlisted, evidence
  # packaged, a resource attested — objects spanning all four FR-06.3 types.
  defp lifecycle_events do
    [
      %{
        "id" => "ev-1",
        "event_type" => "work_order.opened",
        "objects" => ["wo-42:WorkOrder", "agent-7:Agent"],
        "payload" => ~s({"action":"open","order":"wo-42","principal":"agent-7"})
      },
      %{
        "id" => "ev-2",
        "event_type" => "agent.enlisted",
        "objects" => ["wo-42:WorkOrder", "agent-7:Agent"],
        "payload" => ~s({"action":"enlist","agent":"agent-7"})
      },
      %{
        "id" => "ev-3",
        "event_type" => "evidence.packaged",
        "objects" => ["wo-42:WorkOrder", "evp-9:EvidencePackage", "res-3:Resource"],
        "payload_hex" => Base.encode16("{\"action\":\"package\",\"package\":\"evp-9\"}", case: :lower)
      },
      %{
        "id" => "ev-4",
        "event_type" => "resource.attested",
        "objects" => ["evp-9:EvidencePackage", "res-3:Resource"],
        "payload" => ~s({"action":"attest","resource":"res-3"})
      }
    ]
  end

  # Returns the receipt with event `index`'s payload_commitment carrying one
  # different (still-valid lowercase-hex) byte — a real single-byte tamper.
  defp flip_event_commitment_byte(receipt, index) do
    update_in(receipt, ["events", Access.at(index), "payload_commitment"], fn
      <<"a", rest::binary>> -> "b" <> rest
      <<_other, rest::binary>> -> "a" <> rest
    end)
  end

  defp flip_last_hex_nibble(hex) when byte_size(hex) >= 1 do
    {body, <<last>>} = Elixir.String.split_at(hex, byte_size(hex) - 1)

    flipped =
      case last do
        ?d -> ?e
        _ -> ?d
      end

    <<body::binary, flipped>>
  end
end
