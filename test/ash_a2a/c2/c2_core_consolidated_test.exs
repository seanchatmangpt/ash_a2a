# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: C2 Core Courts & Models (Worker 14)
# Contains 24 original test files:
#   - test/ash_a2a/c2/architecture_closure_test.exs
#   - test/ash_a2a/c2/certificate_model_test.exs
#   - test/ash_a2a/c2/court_001_test.exs
#   - test/ash_a2a/c2/court_002_test.exs
#   - test/ash_a2a/c2/court_003_test.exs
#   - test/ash_a2a/c2/court_004_test.exs
#   - test/ash_a2a/c2/court_005_test.exs
#   - test/ash_a2a/c2/court_006_test.exs
#   - test/ash_a2a/c2/court_007_test.exs
#   - test/ash_a2a/c2/court_008_test.exs
#   - test/ash_a2a/c2/court_009_test.exs
#   - test/ash_a2a/c2/court_010_test.exs
#   - test/ash_a2a/c2/court_011_test.exs
#   - test/ash_a2a/c2/court_012_test.exs
#   - test/ash_a2a/c2/court_013_test.exs
#   - test/ash_a2a/c2/court_014_test.exs
#   - test/ash_a2a/c2/court_015_test.exs
#   - test/ash_a2a/c2/court_016_test.exs
#   - test/ash_a2a/c2/court_017_test.exs
#   - test/ash_a2a/c2/court_018_test.exs
#   - test/ash_a2a/c2/court_019_test.exs
#   - test/ash_a2a/c2/court_020_test.exs
#   - test/ash_a2a/c2/court_021_test.exs
#   - test/ash_a2a/c2/court_022_test.exs
# ==============================================================================

# ------------------------------------------------------------------------------
# Section 1: test/ash_a2a/c2/architecture_closure_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.ArchitectureClosureTest do
  use ExUnit.Case, async: true

  alias AshA2A.C2.ArchitectureClosure

  test "protected control plane owns neither signer nor effector" do
    refute ArchitectureClosure.control_plane_signing_authority?()
    refute ArchitectureClosure.in_beam_protected_effector?()

    assert ArchitectureClosure.protected_pipeline() == [
             AshA2A.C2.PreparedEffect,
             AshA2A.C2.AuthorityClient,
             AshA2A.C2.ActuatorClient
           ]
  end
end

# ------------------------------------------------------------------------------
# Section 2: test/ash_a2a/c2/certificate_model_test.exs
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Section 3: test/ash_a2a/c2/court_001_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C001Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 1 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-1", "capability", "subject", %{court: 1})
    b = AshA2A.C2.PreparedEffect.new("principal-1", "capability", "subject", %{court: 2})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 4: test/ash_a2a/c2/court_002_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C002Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 2 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-2", "capability", "subject", %{court: 2})
    b = AshA2A.C2.PreparedEffect.new("principal-2", "capability", "subject", %{court: 3})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 5: test/ash_a2a/c2/court_003_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C003Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 3 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-3", "capability", "subject", %{court: 3})
    b = AshA2A.C2.PreparedEffect.new("principal-3", "capability", "subject", %{court: 4})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 6: test/ash_a2a/c2/court_004_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C004Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 4 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-4", "capability", "subject", %{court: 4})
    b = AshA2A.C2.PreparedEffect.new("principal-4", "capability", "subject", %{court: 5})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 7: test/ash_a2a/c2/court_005_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C005Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 5 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-5", "capability", "subject", %{court: 5})
    b = AshA2A.C2.PreparedEffect.new("principal-5", "capability", "subject", %{court: 6})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 8: test/ash_a2a/c2/court_006_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C006Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 6 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-6", "capability", "subject", %{court: 6})
    b = AshA2A.C2.PreparedEffect.new("principal-6", "capability", "subject", %{court: 7})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 9: test/ash_a2a/c2/court_007_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C007Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 7 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-7", "capability", "subject", %{court: 7})
    b = AshA2A.C2.PreparedEffect.new("principal-7", "capability", "subject", %{court: 8})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 10: test/ash_a2a/c2/court_008_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C008Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 8 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-8", "capability", "subject", %{court: 8})
    b = AshA2A.C2.PreparedEffect.new("principal-8", "capability", "subject", %{court: 9})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 11: test/ash_a2a/c2/court_009_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C009Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 9 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-9", "capability", "subject", %{court: 9})
    b = AshA2A.C2.PreparedEffect.new("principal-9", "capability", "subject", %{court: 10})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 12: test/ash_a2a/c2/court_010_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C010Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 10 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-10", "capability", "subject", %{court: 10})
    b = AshA2A.C2.PreparedEffect.new("principal-10", "capability", "subject", %{court: 11})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 13: test/ash_a2a/c2/court_011_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C011Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 11 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-11", "capability", "subject", %{court: 11})
    b = AshA2A.C2.PreparedEffect.new("principal-11", "capability", "subject", %{court: 12})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 14: test/ash_a2a/c2/court_012_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C012Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 12 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-12", "capability", "subject", %{court: 12})
    b = AshA2A.C2.PreparedEffect.new("principal-12", "capability", "subject", %{court: 13})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 15: test/ash_a2a/c2/court_013_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C013Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 13 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-13", "capability", "subject", %{court: 13})
    b = AshA2A.C2.PreparedEffect.new("principal-13", "capability", "subject", %{court: 14})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 16: test/ash_a2a/c2/court_014_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C014Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 14 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-14", "capability", "subject", %{court: 14})
    b = AshA2A.C2.PreparedEffect.new("principal-14", "capability", "subject", %{court: 15})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 17: test/ash_a2a/c2/court_015_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C015Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 15 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-15", "capability", "subject", %{court: 15})
    b = AshA2A.C2.PreparedEffect.new("principal-15", "capability", "subject", %{court: 16})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 18: test/ash_a2a/c2/court_016_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C016Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 16 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-16", "capability", "subject", %{court: 16})
    b = AshA2A.C2.PreparedEffect.new("principal-16", "capability", "subject", %{court: 17})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 19: test/ash_a2a/c2/court_017_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C017Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 17 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-17", "capability", "subject", %{court: 17})
    b = AshA2A.C2.PreparedEffect.new("principal-17", "capability", "subject", %{court: 18})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 20: test/ash_a2a/c2/court_018_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C018Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 18 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-18", "capability", "subject", %{court: 18})
    b = AshA2A.C2.PreparedEffect.new("principal-18", "capability", "subject", %{court: 19})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 21: test/ash_a2a/c2/court_019_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C019Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 19 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-19", "capability", "subject", %{court: 19})
    b = AshA2A.C2.PreparedEffect.new("principal-19", "capability", "subject", %{court: 20})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 22: test/ash_a2a/c2/court_020_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C020Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 20 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-20", "capability", "subject", %{court: 20})
    b = AshA2A.C2.PreparedEffect.new("principal-20", "capability", "subject", %{court: 21})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 23: test/ash_a2a/c2/court_021_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C021Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 21 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-21", "capability", "subject", %{court: 21})
    b = AshA2A.C2.PreparedEffect.new("principal-21", "capability", "subject", %{court: 22})
    refute a.digest == b.digest
  end
end

# ------------------------------------------------------------------------------
# Section 24: test/ash_a2a/c2/court_022_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C2.Court.C022Test do
  use ExUnit.Case, async: true
  @tag :c2_authority
  test "court 22 exact effect mutation is detectable" do
    a = AshA2A.C2.PreparedEffect.new("principal-22", "capability", "subject", %{court: 22})
    b = AshA2A.C2.PreparedEffect.new("principal-22", "capability", "subject", %{court: 23})
    refute a.digest == b.digest
  end
end
