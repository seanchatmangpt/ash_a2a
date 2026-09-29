defmodule AshA2A.C2.CertificateModelTest do
  @moduledoc """
  Canonical certificate model (docs/reference/c2-certificate.md): the control-plane wire, the
  actuator certificate JSON and the authority service reply all describe ONE `Certificate`.
  DB-free, real bytes, no doubles.
  """
  use ExUnit.Case, async: true

  alias AshA2A.C2.{ActuatorProfile, Certificate, PreparedEffect, Wire}
  alias Sa2aCrypto.{Envelope, SignedMessage}

  defp cert(over \\ %{}) do
    struct!(
      Certificate,
      Map.merge(
        %{
          version: 1,
          effect_digest: "sha256:" <> String.duplicate("a", 64),
          principal: "agent:alice",
          policy_epoch: 3,
          revocation_epoch: 0,
          generation: 1,
          nonce: "cert-nonce",
          not_before_ms: 1_800_000_000_000,
          expires_at_ms: 1_800_000_300_000,
          audience: "actuator:x",
          threshold: 1,
          signatures: [
            %{signer: "k1", kid: "k1", alg: "ES256", nonce: "n1", signature: <<0, 255, 128, 7>>}
          ]
        },
        over
      )
    )
  end

  test "Wire.certificate/1 is JSON-encodable with raw signature bytes and round-trips" do
    c = cert(%{alg: "ES256", kid: "k1"})
    wire = Wire.certificate(c)
    assert {:ok, json} = Jason.encode(wire)
    assert {:ok, decoded} = Wire.decode_certificate(Jason.decode!(json))
    assert decoded.signatures == c.signatures
    assert %{decoded | signatures: []} == %{c | signatures: []}
  end

  test "Wire.decode_certificate/1 refuses a non-base64url signature and a missing field" do
    wire = cert() |> Wire.certificate() |> Jason.encode!() |> Jason.decode!()
    bad = %{wire | "signatures" => [%{"signature" => "not base64!"}]}
    assert {:error, :invalid_certificate_wire} = Wire.decode_certificate(bad)

    assert {:error, :invalid_certificate_wire} =
             Wire.decode_certificate(Map.delete(wire, "threshold"))
  end

  test "opaque external signature evidence without bytes passes through the wire unchanged" do
    c = cert(%{signatures: [%{"key_id" => "external"}]})

    assert {:ok, %{signatures: [%{"key_id" => "external"}]}} =
             c |> Wire.certificate() |> Wire.decode_certificate()
  end

  test "certificate_json/1 renders the actuator form: seconds, per-signature kid/alg/nonce, no extra keys" do
    assert {:ok, bytes} = ActuatorProfile.certificate_json(cert())
    m = Jason.decode!(bytes)
    assert m["not_before"] == 1_800_000_000 and m["expires"] == 1_800_000_300
    assert m["v"] == 1

    assert Enum.sort(Map.keys(m)) ==
             Enum.sort(
               ~w(v effect_digest principal policy_epoch revocation_epoch generation not_before expires audience signatures)
             )

    assert [%{"kid" => "k1", "alg" => "ES256", "nonce" => "n1", "signature" => sig}] =
             m["signatures"]

    assert Envelope.b64(sig) == {:ok, <<0, 255, 128, 7>>}
    assert Jcs.encode(m) == bytes
  end

  test "certificate_json/1 refuses sub-second time and signature entries without bytes" do
    assert {:error, :sub_second_time} =
             ActuatorProfile.certificate_json(cert(%{expires_at_ms: 1_800_000_300_001}))

    assert {:error, :malformed_certificate} =
             ActuatorProfile.certificate_json(cert(%{signatures: [%{"key_id" => "x"}]}))

    assert {:error, :malformed_certificate} =
             ActuatorProfile.certificate_json(cert(%{signatures: []}))
  end

  test "certificate_from_authority/1 maps the service reply (seconds) to the struct (ms) and back" do
    fields = %{
      "v" => 1,
      "alg" => "ES256",
      "kid" => "kid-1",
      "effect_digest" => "sha256:" <> String.duplicate("b", 64),
      "principal" => "agent:alice",
      "policy_epoch" => 3,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "n-1",
      "not_before" => 1_800_000_000,
      "expires" => 1_800_000_900,
      "audience" => "actuator:x"
    }

    {:ok, msg} = SignedMessage.build(fields)

    env = %Envelope{
      v: 1,
      alg: "ES256",
      kid: "kid-1",
      profile: :classical,
      signed_bytes_digest: SignedMessage.digest(msg),
      signature: <<1, 2, 3>>,
      nonce: "n-1",
      not_before: 1_800_000_000,
      expires: 1_800_000_900,
      audience: "actuator:x"
    }

    {:ok, env_json} = Envelope.encode(env)

    reply = %{
      "envelope" => Jason.decode!(env_json),
      "message" => Base.url_encode64(msg, padding: false)
    }

    assert {:ok, c} = ActuatorProfile.certificate_from_authority(reply)
    assert c.not_before_ms == 1_800_000_000_000 and c.expires_at_ms == 1_800_000_900_000

    assert c.signatures == [
             %{signer: "kid-1", kid: "kid-1", alg: "ES256", nonce: "n-1", signature: <<1, 2, 3>>}
           ]

    assert {:ok, m} =
             c |> ActuatorProfile.certificate_json() |> then(fn {:ok, b} -> Jason.decode(b) end)

    assert m["not_before"] == 1_800_000_000 and m["expires"] == 1_800_000_900

    # message and envelope that disagree are refused
    tampered = put_in(reply, ["envelope", "nonce"], "n-2")
    assert {:error, _} = ActuatorProfile.certificate_from_authority(tampered)

    assert {:error, :malformed_certificate} =
             ActuatorProfile.certificate_from_authority(%{"x" => 1})
  end

  test "ActuatorProfile.effect/2 yields the actuator's exact canonical bytes and refuses other payloads" do
    e =
      PreparedEffect.new("agent:alice", "actuator.ledger.append", "subject:orders/42", %{
        effect_type: "ledger_append",
        consequence_class: "internal_append",
        effect_instance_id: "ei:0001-abcdef",
        resource_bounds: %{max_bytes: 256},
        params: %{entry: "hello"}
      })

    assert {:ok, %{map: m, bytes: bytes, digest: d}} = ActuatorProfile.effect(e, 3)
    assert Jcs.encode(m) == bytes
    assert d == SignedMessage.digest(bytes)
    assert m["policy_epoch"] == 3 and m["v"] == 1 and m["params"] == %{"entry" => "hello"}
    refute d == e.digest

    other = PreparedEffect.new("agent:alice", "cap", "s", %{"amount" => 1})
    assert {:error, :payload_profile} = ActuatorProfile.effect(other, 3)
    assert {:error, :payload_profile} = ActuatorProfile.effect(e, -1)
  end
end
