# Generates an Elixir-signed approval fixture for the Swift reverse-direction test.
# Usage: elixir sa2a-approver/scripts/gen_elixir_fixture.exs <out_dir>
# Plain :crypto only; the JSON below is written already in JCS form (keys sorted, no spaces).
[out] = System.argv()
File.mkdir_p!(out)

{pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
header = Base.decode16!("3059301306072A8648CE3D020106082A8648CE3D030107034200")
spki = header <> pub
kid = :crypto.hash(:sha256, spki) |> binary_part(0, 16) |> Base.url_encode64(padding: false)

effect = ~s({"capability":"repo.merge","inputs":{"pr":77},"target":"org/elixir-signed"})
digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, effect), case: :lower)

json =
  ~s({"alg":"ES256","audience":"actuator:prod-1","effect_digest":"#{digest}",) <>
    ~s("expires":1800000300,"generation":9,"kid":"#{kid}","nonce":"elixir-nonce-1",) <>
    ~s("not_before":1800000000,"policy_epoch":7,"principal":"human:bob","revocation_epoch":3,"v":1})

msg = "SA2A-C2-APPROVAL-v1" <> <<0>> <> json
sig = :crypto.sign(:ecdsa, :sha256, msg, [priv, :secp256r1])

File.write!(Path.join(out, "message.bin"), msg)
File.write!(Path.join(out, "effect.json"), effect)
File.write!(Path.join(out, "signature.der"), sig)
File.write!(Path.join(out, "spki.der"), spki)
File.write!(Path.join(out, "kid.txt"), kid)
IO.puts("wrote elixir fixture kid=#{kid}")
