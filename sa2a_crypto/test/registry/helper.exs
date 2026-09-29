defmodule Sa2aCrypto.RegistryHelper do
  @moduledoc false
  # Real ES256 keys, real signatures made with :crypto directly (an oracle independent of
  # Sa2aCrypto.Native.verify). Each signer signs bytes that embed its own kid.
  alias Sa2aCrypto.{Fixtures, KeyRecord, KeyRef, SignedMessage}

  def tmp_dir(name) do
    dir =
      Path.join(System.tmp_dir!(), "sa2a_reg_#{name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc "A signer: %{record, priv, kid}."
  def new_key(custodian, tier \\ :i2, over \\ []) do
    {pub, priv} = Fixtures.keypair("ES256")
    kid = KeyRef.kid!("ES256", pub)

    record =
      struct!(
        KeyRecord,
        Keyword.merge(
          [
            kid: kid,
            alg: "ES256",
            public_key: pub,
            custodian_id: custodian,
            custody_tier: tier,
            state: :active,
            revocation_epoch: 0
          ],
          over
        )
      )

    %{record: record, priv: priv, kid: kid}
  end

  @doc "Envelope+bytes signed by `signing_priv` (default the key's own) for `key.kid`."
  def approve(key, over \\ %{}, signing_priv \\ nil) do
    fields = Fixtures.base_fields("ES256", key.kid, over)
    {:ok, bytes} = SignedMessage.build(fields)
    sig = Fixtures.raw_sign("ES256", bytes, signing_priv || key.priv)
    {Fixtures.envelope(fields, bytes, sig), bytes}
  end

  def policy(k, extra \\ []),
    do: Map.merge(%{k: k, audience: Fixtures.audience(), now: Fixtures.now()}, Map.new(extra))

  def enroll_all(path, pin, keys) do
    Enum.reduce(keys, pin, fn key, pin ->
      {:ok, root} = Sa2aCrypto.Registry.File.enroll(path, key.record, pin: pin)
      root
    end)
  end
end
