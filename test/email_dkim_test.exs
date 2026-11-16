defmodule AshA2A.EmailDkimTest do
  @moduledoc """
  W2-07: `AshA2A.Email.Dkim` against real RSA keys (`:public_key.generate_key/1`) and real
  signed messages built by an independent test-side signer. Standing: UNVERIFIED (not run; no
  Elixir toolchain when written).
  """
  use ExUnit.Case, async: true

  alias AshA2A.Email.Dkim

  @now 1_800_000_000

  setup_all do
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = priv = :public_key.generate_key({:rsa, 2048, 65537})
    pub = {:RSAPublicKey, n, e}
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, pub)

    {:RSAPrivateKey, _, n2, e2, _, _, _, _, _, _, _} = other = :public_key.generate_key({:rsa, 2048, 65537})
    _ = {n2, e2}
    {:ok, priv: priv, other: other, p: Base.encode64(der), pub: pub}
  end

  defp resolver(p), do: fn "example.com", "sel" -> {:ok, p}; _, _ -> {:error, :nxdomain} end
  defp opts(p, extra \\ []), do: [key_resolver: resolver(p), now: fn -> @now end] ++ extra

  defp canon_body(body) do
    lines =
      body
      |> String.split("\r\n")
      |> Enum.map(&(&1 |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing()))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    if lines == [], do: "", else: Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp canon_hdr({n, v}),
    do: String.downcase(n) <> ":" <> (v |> String.replace(~r/[ \t]+/, " ") |> String.trim())

  # Signs `headers` (list of {name, value}) + `body`; returns the full raw message.
  defp sign(priv, headers, body, o \\ []) do
    h = Keyword.get(o, :h, ["from", "to", "subject"])
    bh = :crypto.hash(:sha256, canon_body(body)) |> Base.encode64()

    extra = Keyword.get(o, :tags, "")

    value =
      "v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.com; s=sel; h=#{Enum.join(h, ":")}; bh=#{bh};#{extra} b="

    signed =
      Enum.map(h, fn name ->
        headers |> Enum.reverse() |> Enum.find(fn {n, _} -> String.downcase(n) == name end)
      end)
      |> Enum.reject(&is_nil/1)

    data =
      Enum.map_join(signed, &(canon_hdr(&1) <> "\r\n")) <> canon_hdr({"DKIM-Signature", value})

    sig = :public_key.sign(data, :sha256, priv) |> Base.encode64()
    folded = sig |> String.graphemes() |> Enum.chunk_every(60) |> Enum.map_join("\r\n\t", &Enum.join/1)

    all = [{"DKIM-Signature", " " <> value <> folded}] ++ headers
    Enum.map_join(all, &("#{elem(&1, 0)}:#{elem(&1, 1)}\r\n")) <> "\r\n" <> body
  end

  defp headers do
    [
      {"From", " Alice <alice@example.com>"},
      {"To", " bob@example.org"},
      {"Subject", " Hello   there"}
    ]
  end

  @body "Approve 1.\r\n  trailing   spaces \r\n\r\n"

  test "valid rsa-sha256 relaxed/relaxed signature verifies", ctx do
    msg = sign(ctx.priv, headers(), @body)
    assert :ok = Dkim.verify(msg, opts(ctx.p))
    assert Dkim.verifier(opts(ctx.p)).(msg) == true
    assert Dkim.verifier(opts(ctx.p)).(%{"content" => msg}) == true
  end

  test "relaxed canonicalization tolerates whitespace rewrites in headers and body", ctx do
    msg = sign(ctx.priv, headers(), @body)
    rewritten = String.replace(msg, "Hello   there", "Hello there") |> String.replace("trailing   spaces ", "trailing spaces")
    assert :ok = Dkim.verify(rewritten, opts(ctx.p))
  end

  test "SNS-style envelope carrying content verifies", ctx do
    msg = sign(ctx.priv, headers(), @body)
    sns = %{"Message" => Jason.encode!(%{"content" => msg})}
    assert Dkim.verifier(opts(ctx.p)).(sns) == true
  end

  test "tampered body is refused", ctx do
    msg = sign(ctx.priv, headers(), @body)
    assert {:error, :body_hash_mismatch} = Dkim.verify(String.replace(msg, "Approve 1.", "Approve 9."), opts(ctx.p))
  end

  test "tampered signed header is refused", ctx do
    msg = sign(ctx.priv, headers(), @body)
    bad = String.replace(msg, "Subject: Hello", "Subject: Goodbye")
    assert {:error, :bad_signature} = Dkim.verify(bad, opts(ctx.p))
    assert Dkim.verifier(opts(ctx.p)).(bad) == false
  end

  test "wrong key (signed by someone else) is refused", ctx do
    msg = sign(ctx.other, headers(), @body)
    assert {:error, :bad_signature} = Dkim.verify(msg, opts(ctx.p))
  end

  test "appended unsigned From header is refused", ctx do
    msg = sign(ctx.priv, headers(), @body)
    bad = String.replace(msg, "To:", "From: evil@example.com\r\nTo:", global: false)
    assert {:error, :multiple_from} = Dkim.verify(bad, opts(ctx.p))
  end

  test "l= truncation is refused even with a valid signature", ctx do
    msg = sign(ctx.priv, headers(), @body, tags: " l=5;")
    assert {:error, :body_length_limit} = Dkim.verify(msg, opts(ctx.p))
  end

  test "h= not covering from is refused", ctx do
    msg = sign(ctx.priv, headers(), @body, h: ["to", "subject"])
    assert {:error, :from_not_signed} = Dkim.verify(msg, opts(ctx.p))
  end

  test "expired x= is refused; unexpired accepted", ctx do
    expired = sign(ctx.priv, headers(), @body, tags: " x=#{@now - 1};")
    assert {:error, :expired} = Dkim.verify(expired, opts(ctx.p))
    fresh = sign(ctx.priv, headers(), @body, tags: " x=#{@now + 3600};")
    assert :ok = Dkim.verify(fresh, opts(ctx.p))
  end

  test "From domain not aligned with d= is refused unless disabled", ctx do
    hs = [{"From", " Mallory <m@evil.test>"} | tl(headers())]
    msg = sign(ctx.priv, hs, @body)
    assert {:error, :from_misaligned} = Dkim.verify(msg, opts(ctx.p))
    assert :ok = Dkim.verify(msg, opts(ctx.p, require_from_alignment: false))
  end

  test "missing, revoked, bogus and weak keys are refused", ctx do
    msg = sign(ctx.priv, headers(), @body)
    assert {:error, :key_unavailable} = Dkim.verify(msg, key_resolver: fn _, _ -> {:error, :nxdomain} end, now: fn -> @now end)
    assert {:error, :key_unavailable} = Dkim.verify(msg, key_resolver: fn _, _ -> raise "dns" end, now: fn -> @now end)
    assert {:error, :key_revoked} = Dkim.verify(msg, opts(""))
    assert {:error, :bad_key} = Dkim.verify(msg, opts("bm90IGEga2V5"))

    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = :public_key.generate_key({:rsa, 512, 65537})
    {:SubjectPublicKeyInfo, der, _} = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})
    assert {:error, :weak_key} = Dkim.verify(msg, opts(Base.encode64(der)))
  end

  test "unsupported algorithm and canonicalization are refused", ctx do
    msg = sign(ctx.priv, headers(), @body)
    assert {:error, :unsupported_algorithm} = Dkim.verify(String.replace(msg, "rsa-sha256", "rsa-sha1"), opts(ctx.p))
    assert {:error, :unsupported_canonicalization} = Dkim.verify(String.replace(msg, "relaxed/relaxed", "simple/simple"), opts(ctx.p))
  end

  test "unsigned message and non-binary input are refused", ctx do
    assert {:error, :no_signature} = Dkim.verify("From: a@example.com\r\n\r\nhi\r\n", opts(ctx.p))
    assert Dkim.verifier(opts(ctx.p)).(%{"nope" => 1}) == false
    assert Dkim.verifier(opts(ctx.p)).(nil) == false
  end
end
