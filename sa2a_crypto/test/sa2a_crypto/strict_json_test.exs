defmodule Sa2aCrypto.StrictJsonTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.{Envelope, SignedMessage, StrictJson}

  test "duplicate keys refused at any depth" do
    assert {:error, :duplicate_key} = StrictJson.decode(~s({"a":1,"a":2}))

    assert {:error, :duplicate_key} =
             StrictJson.decode(~s({"x":[{"a":1,"a":1}]}), canonical: false)
  end

  test "non-canonical input refused, canonical accepted" do
    assert {:error, :non_canonical} = StrictJson.decode(~s({"b":1,"a":2}))
    assert {:error, :non_canonical} = StrictJson.decode(~s({"a": 1}))
    assert {:ok, %{"a" => 2, "b" => 1}} = StrictJson.decode(~s({"a":2,"b":1}))
    assert {:ok, _} = StrictJson.decode(~s({"b":1,"a":2}), canonical: false)
  end

  test "Envelope.decode refuses duplicate keys and non-canonical wire form" do
    env = %Envelope{
      v: 1,
      alg: "ES256",
      kid: "k",
      profile: :classical,
      signed_bytes_digest: "sha256:00",
      signature: <<1, 2, 3>>,
      nonce: "n",
      not_before: 1,
      expires: 2,
      audience: "a"
    }

    {:ok, json} = Envelope.encode(env)
    assert {:ok, _} = Envelope.decode(json)
    dup = String.replace(json, ~s("v":1), ~s("v":1,"v":1))
    assert {:error, :malformed_envelope} = Envelope.decode(dup)
    spaced = String.replace(json, ~s("alg":"ES256",), ~s("alg": "ES256",))
    assert {:error, :malformed_envelope} = Envelope.decode(spaced)
  end

  test "SignedMessage.parse refuses duplicate keys and non-canonical bodies" do
    fields = %{
      "v" => 1,
      "alg" => "ES256",
      "kid" => "k",
      "effect_digest" => "sha256:0",
      "principal" => "p",
      "policy_epoch" => 1,
      "revocation_epoch" => 0,
      "generation" => 1,
      "nonce" => "n",
      "not_before" => 1,
      "expires" => 2,
      "audience" => "a"
    }

    {:ok, bytes} = SignedMessage.build(fields)
    assert {:ok, _} = SignedMessage.parse(bytes)
    pre = SignedMessage.prefix()
    <<^pre::binary-size(byte_size(pre)), json::binary>> = bytes
    dup = pre <> String.replace(json, ~s("v":1), ~s("v":1,"v":2))
    assert {:error, :malformed_message} = SignedMessage.parse(dup)
    assert {:error, :malformed_message} = SignedMessage.parse(pre <> " " <> json)
  end
end
