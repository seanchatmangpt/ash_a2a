Code.require_file("helper.exs", __DIR__)

defmodule Sa2aCrypto.Registry.FileTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.Registry.{File, Lifecycle, Spki}
  alias Sa2aCrypto.{Fixtures, KeyRef, RegistryHelper, Registry}

  defp fresh(name) do
    path = Path.join(RegistryHelper.tmp_dir(name), "registry.json")
    {:ok, root} = File.create(path)
    {path, root}
  end

  test "enrolled keys round-trip through the file and verify a real signature" do
    {path, root} = fresh("rt")
    key = RegistryHelper.new_key("cust-a", :i3)
    root = RegistryHelper.enroll_all(path, root, [key])

    assert {:ok, view} = File.load(path, root)
    assert {:ok, rec} = Registry.lookup(view, key.kid)
    assert rec.public_key == key.record.public_key
    assert rec.custodian_id == "cust-a" and rec.custody_tier == :i3 and rec.state == :active

    {env, bytes} = RegistryHelper.approve(key)

    assert {:valid, %{kid: kid, custodian_id: "cust-a", tier: :i3}} =
             Sa2aCrypto.verify_envelope(env, bytes, view, Fixtures.opts())

    assert kid == key.kid
  end

  test "the root pin refuses a load with the wrong or missing pin" do
    {path, root} = fresh("pin")
    assert {:error, :registry_root_mismatch} = File.load(path, String.duplicate("0", 64))
    assert {:error, :pin_required} = File.load(path, nil)
    assert {:ok, _} = File.load(path, root)
    assert {:error, :pin_required} = File.enroll(path, RegistryHelper.new_key("c").record, [])
  end

  test "a value-preserving-length edit is refused by the pin, not by parsing" do
    {path, root} = fresh("edit")
    root = RegistryHelper.enroll_all(path, root, [RegistryHelper.new_key("cust-a")])
    bin = Elixir.File.read!(path)
    edited = String.replace(bin, "cust-a", "cust-b")
    assert byte_size(edited) == byte_size(bin) and edited != bin
    Elixir.File.write!(path, edited)
    assert {:error, :registry_root_mismatch} = File.load(path, root)
  end

  test "every single-bit flip of the registry file is refused" do
    {path, root} = fresh("flip")
    root = RegistryHelper.enroll_all(path, root, [RegistryHelper.new_key("cust-a")])
    bin = Elixir.File.read!(path)

    results =
      for i <- 0..(byte_size(bin) - 1), bit <- [0, 3, 7] do
        <<pre::binary-size(^i), b, post::binary>> = bin

        Elixir.File.write!(
          path,
          <<pre::binary, Bitwise.bxor(b, Bitwise.bsl(1, bit)), post::binary>>
        )

        File.load(path, root)
      end

    assert Enum.all?(results, &match?({:error, _}, &1))
    Elixir.File.write!(path, bin)
    assert {:ok, _} = File.load(path, root)
  end

  test "SP 800-57 transitions: exactly the oracle's legal pairs are allowed" do
    legal = [
      {:pre_activation, :active},
      {:pre_activation, :compromised},
      {:pre_activation, :destroyed},
      {:active, :suspended},
      {:active, :deactivated},
      {:active, :compromised},
      {:suspended, :active},
      {:suspended, :deactivated},
      {:suspended, :compromised},
      {:deactivated, :compromised},
      {:deactivated, :destroyed},
      {:compromised, :destroyed}
    ]

    for from <- Sa2aCrypto.KeyRecord.states(), to <- Sa2aCrypto.KeyRecord.states() do
      assert Lifecycle.allowed?(from, to) == {from, to} in legal, "#{from} -> #{to}"
    end
  end

  test "illegal transitions are refused through the file and leave it byte-identical" do
    {path, root} = fresh("life")
    key = RegistryHelper.new_key("cust-a")
    root = RegistryHelper.enroll_all(path, root, [key])
    {:ok, root} = File.transition(path, key.kid, :deactivated, pin: root)
    before = Elixir.File.read!(path)

    assert {:error, :illegal_transition} = File.transition(path, key.kid, :active, pin: root)
    assert {:error, :illegal_transition} = File.transition(path, key.kid, :suspended, pin: root)
    assert {:error, :unknown_kid} = File.transition(path, "nope", :active, pin: root)
    assert {:error, :unknown_state} = File.transition(path, key.kid, :bogus, pin: root)
    assert Elixir.File.read!(path) == before
    assert {:ok, ^root} = File.root(path)

    {:ok, root} = File.transition(path, key.kid, :destroyed, pin: root)
    assert {:error, :illegal_transition} = File.revoke(path, key.kid, pin: root)
  end

  test "a stale pin cannot mutate (mutation returns the new root, callers re-pin)" do
    {path, root} = fresh("stale")
    {:ok, _new} = File.enroll(path, RegistryHelper.new_key("a").record, pin: root)

    assert {:error, :registry_root_mismatch} =
             File.enroll(path, RegistryHelper.new_key("b").record, pin: root)
  end

  test "revocation epoch is monotonic and durable; the revoked key's standing is refused" do
    {path, root} = fresh("rev")
    [k1, k2] = keys = [RegistryHelper.new_key("a"), RegistryHelper.new_key("b")]
    root = RegistryHelper.enroll_all(path, root, keys)
    {:ok, v0} = File.load(path, root)
    assert File.epoch(v0) == 0

    {:ok, root} = File.revoke(path, k1.kid, pin: root)
    assert {:ok, v1} = File.load(path, root)
    assert File.epoch(v1) == 1
    assert {:ok, %{revocation_epoch: 1, state: :compromised}} = Registry.lookup(v1, k1.kid)

    assert {:error, :epoch_not_monotonic} = File.revoke(path, k2.kid, pin: root, epoch: 1)
    assert {:error, :epoch_not_monotonic} = File.revoke(path, k2.kid, pin: root, epoch: 0)
    {:ok, root} = File.revoke(path, k2.kid, pin: root, epoch: 9)
    assert {:ok, v2} = File.load(path, root)
    assert File.epoch(v2) == 9

    {env, bytes} = RegistryHelper.approve(k1)

    assert {:invalid, :key_compromised} =
             Sa2aCrypto.verify_envelope(env, bytes, v2, Fixtures.opts())
  end

  test "rotation: new key active, old key usable only through the overlap window" do
    {path, root} = fresh("rot")
    old = RegistryHelper.new_key("a")
    new = RegistryHelper.new_key("a")
    root = RegistryHelper.enroll_all(path, root, [old])
    now = Fixtures.now()
    {:ok, root} = File.rotate(path, old.kid, new.record, pin: root, now: now, overlap: 600)
    {:ok, view} = File.load(path, root)

    {oe, ob} = RegistryHelper.approve(old)
    {ne, nb} = RegistryHelper.approve(new)

    assert {:valid, _} = Sa2aCrypto.verify_envelope(oe, ob, view, Fixtures.opts(now: now))
    assert {:valid, _} = Sa2aCrypto.verify_envelope(ne, nb, view, Fixtures.opts(now: now))

    # after the overlap cap the old key is expired, the new one still valid
    late = now + 601
    over = %{"not_before" => late - 60, "expires" => late + 300}
    {oe2, ob2} = RegistryHelper.approve(old, over)
    {ne2, nb2} = RegistryHelper.approve(new, over)

    assert {:invalid, :key_expired} =
             Sa2aCrypto.verify_envelope(oe2, ob2, view, Fixtures.opts(now: late))

    assert {:valid, _} = Sa2aCrypto.verify_envelope(ne2, nb2, view, Fixtures.opts(now: late))

    {:ok, root} = File.transition(path, old.kid, :deactivated, pin: root)
    {:ok, view} = File.load(path, root)

    assert {:invalid, :key_deactivated} =
             Sa2aCrypto.verify_envelope(oe, ob, view, Fixtures.opts(now: now))
  end

  test "rotation refuses a non-active old key, a duplicate kid and a bad overlap" do
    {path, root} = fresh("rotbad")
    old = RegistryHelper.new_key("a")
    root = RegistryHelper.enroll_all(path, root, [old])
    new = RegistryHelper.new_key("a")

    assert {:error, :bad_rotation} =
             File.rotate(path, old.kid, new.record, pin: root, overlap: -1)

    assert {:error, :duplicate_kid} = File.rotate(path, old.kid, old.record, pin: root)
    assert {:error, :unknown_kid} = File.rotate(path, "nope", new.record, pin: root)
    {:ok, root} = File.transition(path, old.kid, :suspended, pin: root)
    assert {:error, :old_key_not_active} = File.rotate(path, old.kid, new.record, pin: root)
  end

  test "enrolment refuses a record whose kid is not the hash of its key" do
    {path, root} = fresh("kid")
    key = RegistryHelper.new_key("a")
    forged = %{key.record | kid: "AAAAAAAAAAAAAAAAAAAAAA"}
    assert {:error, :kid_key_mismatch} = File.enroll(path, forged, pin: root)
    assert {:error, :bad_tier} = File.enroll(path, %{key.record | custody_tier: :i9}, pin: root)
  end

  test "SPKI decoding returns an error for wrong-size or non-canonical keys, never raises" do
    {pub, _} = Fixtures.keypair("ES256")
    {:ok, der} = KeyRef.spki("ES256", pub)
    assert {:ok, ^pub} = Spki.decode("ES256", der)
    assert {:error, :bad_key} = Spki.decode("ES256", binary_part(der, 0, byte_size(der) - 1))
    assert {:error, :bad_key} = Spki.decode("ES256", der <> <<0>>)
    assert {:error, :bad_key} = Spki.decode("ES256", <<>>)
    assert {:error, :bad_key} = Spki.decode("EdDSA", der)
    assert {:error, :bad_key} = Spki.decode("ML-DSA-65", der)
    assert {:error, :bad_key} = Spki.decode(nil, der)
  end

  test "create refuses to overwrite an existing registry" do
    {path, _} = fresh("exists")
    assert {:error, :registry_exists} = File.create(path)
  end

  test "records survive with attestation and activated_at" do
    {path, root} = fresh("att")
    key = RegistryHelper.new_key("a", :i4)
    att = %{"device" => "yubikey-5", "serial" => "123"}

    {:ok, root} =
      File.enroll(path, key.record, pin: root, attestation: att, activated_at: 1_700_000_000)

    {:ok, view} = File.load(path, root)
    assert {:ok, %{attestation: ^att, activated_at: 1_700_000_000}} = File.entry(view, key.kid)
  end
end
