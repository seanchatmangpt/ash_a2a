# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.C1Closure.CertificateStrictJsonTest do
  @moduledoc """
  Control-plane certificate decode refuses duplicate JSON object keys (last-wins /
  first-wins parser differentials let two verifiers read different certificates from one
  byte string). Real bytes, no doubles.
  """
  use ExUnit.Case, async: true

  alias AshA2A.C2.{Certificate, Wire}

  defp wire_map do
    %{
      "version" => 1,
      "effect_digest" => "sha256:" <> String.duplicate("a", 64),
      "principal" => "agent:alice",
      "policy_epoch" => 3,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "cert-nonce",
      "not_before_ms" => 1_800_000_000_000,
      "expires_at_ms" => 1_800_000_300_000,
      "audience" => "actuator:x",
      "threshold" => 1,
      "signatures" => [%{"signer" => "k1", "kid" => "k1", "signature" => "AAECAw"}]
    }
  end

  test "Certificate.decode/1 accepts a well-formed certificate JSON binary" do
    assert {:ok, %Certificate{threshold: 1, audience: "actuator:x"}} =
             Certificate.decode(Jason.encode!(wire_map()))
  end

  test "top-level duplicate key is refused (threshold 1 vs 0)" do
    json = ~s({"threshold":0,) <> String.trim_leading(Jason.encode!(wire_map()), "{")
    assert %{} = Jason.decode!(json)
    assert {:error, :duplicate_json_key} = Certificate.decode(json)
    assert {:error, :duplicate_json_key} = Wire.decode_certificate(json)
  end

  test "nested duplicate key inside a signature entry is refused" do
    json =
      String.replace(
        Jason.encode!(wire_map()),
        ~s("kid":"k1"),
        ~s("kid":"k1","kid":"evil")
      )

    assert {:error, :duplicate_json_key} = Certificate.decode(json)
  end

  test "malformed JSON and non-object roots are refused, maps still decode" do
    assert {:error, :invalid_certificate_wire} = Certificate.decode("{nope")
    assert {:error, :invalid_certificate_wire} = Certificate.decode("[1,2]")
    assert {:ok, %Certificate{}} = Certificate.decode(wire_map())
  end

  describe "RFC 8259 trailing whitespace only (space, tab, LF, CR)" do
    test "insignificant trailing whitespace is accepted" do
      json = Jason.encode!(wire_map())
      assert {:ok, %Certificate{}} = Certificate.decode(json <> " \t\r\n")
    end

    test "trailing non-JSON whitespace (NBSP, VT, FF, U+2003) is refused" do
      json = Jason.encode!(wire_map())

      for tail <- [<<0xC2, 0xA0>>, "\v", "\f", <<0xE2, 0x80, 0x83>>, "\0"] do
        assert {:error, :invalid_certificate_wire} = Certificate.decode(json <> tail),
               inspect(tail)

        assert {:error, :invalid_certificate_wire} = Wire.strict_json(~s({"a":1}) <> tail)
      end
    end
  end
end
