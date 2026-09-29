Code.require_file("helper.exs", __DIR__)

defmodule Sa2aCrypto.QuorumTest do
  use ExUnit.Case, async: true
  alias Sa2aCrypto.Registry.{File, Static}
  alias Sa2aCrypto.{Quorum, RegistryHelper}

  defp view(keys), do: Static.view(Enum.map(keys, & &1.record))
  defp items(pairs), do: pairs
  defp signed(keys, over \\ %{}), do: Enum.map(keys, &RegistryHelper.approve(&1, over))

  test "two kids of one custodian count once" do
    [a1, a2, b] = keys = for c <- ["A", "A", "B"], do: RegistryHelper.new_key(c)
    pairs = signed([a1, a2])

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(pairs, nil, view(keys), RegistryHelper.policy(2))

    assert {:ok, %{custodians: ["A"], signers: [_]}} =
             Quorum.evaluate(pairs, nil, view(keys), RegistryHelper.policy(1))

    assert {:ok, %{custodians: ["A", "B"], k: 2}} =
             Quorum.evaluate(signed([a1, a2, b]), nil, view(keys), RegistryHelper.policy(2))
  end

  test "the same kid submitted twice counts once" do
    [a, _b] = keys = [RegistryHelper.new_key("A"), RegistryHelper.new_key("B")]
    pairs = signed([a, a])

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(pairs, nil, view(keys), RegistryHelper.policy(2))
  end

  test "a claimed signer label without a verifiable signature counts 0" do
    [a, b] = keys = [RegistryHelper.new_key("A"), RegistryHelper.new_key("B")]
    attacker = RegistryHelper.new_key("evil")
    good = RegistryHelper.approve(a)
    # b's kid and well-formed envelope, signed with the attacker's key
    forged = RegistryHelper.approve(b, %{}, attacker.priv)
    # a truncated/garbage signature on b's message
    {env, bytes} = RegistryHelper.approve(b)
    garbage = {%{env | signature: <<1, 2, 3>>}, bytes}
    # an envelope for a kid the registry has never seen
    unknown = RegistryHelper.approve(attacker)
    # a bare label map
    label = {%{"kid" => b.kid, "signer" => "B"}, bytes}

    for bad <- [forged, garbage, unknown, label] do
      assert {:error, :quorum_not_met} =
               Quorum.evaluate([good, bad], nil, view(keys), RegistryHelper.policy(2))
    end

    assert {:ok, %{custodians: ["A"]}} =
             Quorum.evaluate(
               [good, forged, garbage, unknown, label],
               nil,
               view(keys),
               RegistryHelper.policy(1)
             )
  end

  test "message may be shared bytes, a kid map or a function" do
    [a, b] = keys = [RegistryHelper.new_key("A"), RegistryHelper.new_key("B")]
    [{ea, ba}, {eb, bb}] = signed([a, b])
    v = view(keys)
    p = RegistryHelper.policy(2)
    assert {:ok, _} = Quorum.evaluate([ea, eb], %{a.kid => ba, b.kid => bb}, v, p)

    assert {:ok, _} =
             Quorum.evaluate([ea, eb], fn e -> if e.kid == a.kid, do: ba, else: bb end, v, p)

    assert {:error, :quorum_not_met} = Quorum.evaluate([ea, eb], ba, v, p)
  end

  test "signers approving different effect digests do not combine" do
    [a, b] = keys = [RegistryHelper.new_key("A"), RegistryHelper.new_key("B")]
    d1 = "sha256:" <> String.duplicate("11", 32)
    d2 = "sha256:" <> String.duplicate("22", 32)

    pairs = [
      RegistryHelper.approve(a, %{"effect_digest" => d1}),
      RegistryHelper.approve(b, %{"effect_digest" => d2})
    ]

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(pairs, nil, view(keys), RegistryHelper.policy(2))

    same = [
      RegistryHelper.approve(a, %{"effect_digest" => d1}),
      RegistryHelper.approve(b, %{"effect_digest" => d1})
    ]

    assert {:ok, %{effect_digest: ^d1}} =
             Quorum.evaluate(same, nil, view(keys), RegistryHelper.policy(2))

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(same, nil, view(keys), RegistryHelper.policy(2, effect_digest: d2))
  end

  test "required tier: lower-tier custodians do not count; reported tier is the minimum" do
    [a, b, c] =
      keys = [
        RegistryHelper.new_key("A", :i1),
        RegistryHelper.new_key("B", :i2),
        RegistryHelper.new_key("C", :i3)
      ]

    pairs = signed([a, b, c])
    v = view(keys)
    assert {:ok, %{tier: :i1}} = Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(3))

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(3, tier: :i2))

    assert {:ok, %{tier: :i2, custodians: ["B", "C"]}} =
             Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(2, tier: :i2))
  end

  test "signer allowlist (the n of k-of-n) excludes registry-valid outsiders" do
    [a, b, c] = keys = for x <- ["A", "B", "C"], do: RegistryHelper.new_key(x)
    pairs = signed([a, b, c])
    p = RegistryHelper.policy(2, signer_kids: [a.kid, c.kid])
    assert {:ok, %{custodians: ["A", "C"]}} = Quorum.evaluate(pairs, nil, view(keys), p)

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(
               pairs,
               nil,
               view(keys),
               RegistryHelper.policy(3, signer_kids: [a.kid, c.kid])
             )
  end

  test "non-active keys never count (suspended, deactivated, expired)" do
    keys = [
      RegistryHelper.new_key("A"),
      RegistryHelper.new_key("B", :i2, state: :suspended),
      RegistryHelper.new_key("C", :i2, state: :deactivated),
      RegistryHelper.new_key("D", :i2, not_after: 1)
    ]

    assert {:ok, %{custodians: ["A"]}} =
             Quorum.evaluate(signed(keys), nil, view(keys), RegistryHelper.policy(1))

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(signed(keys), nil, view(keys), RegistryHelper.policy(2))
  end

  test "a revoked kid at/before the certificate epoch is refused (file registry)" do
    path = Path.join(RegistryHelper.tmp_dir("revq"), "registry.json")
    {:ok, root} = File.create(path)
    [a, b] = keys = [RegistryHelper.new_key("A"), RegistryHelper.new_key("B")]
    root = RegistryHelper.enroll_all(path, root, keys)
    {:ok, v} = File.load(path, root)
    pairs = signed(keys)
    assert {:ok, _} = Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(2, epoch: 0))

    {:ok, root} = File.revoke(path, b.kid, pin: root)
    {:ok, v} = File.load(path, root)
    assert File.epoch(v) == 1

    for epoch <- [0, 1, 5] do
      assert {:error, :quorum_not_met} =
               Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(2, epoch: epoch))
    end

    assert {:ok, %{custodians: ["A"]}} = Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(1))
    _ = a
  end

  test "a key stamped after the certificate epoch is refused" do
    a = RegistryHelper.new_key("A", :i2, revocation_epoch: 9)
    b = RegistryHelper.new_key("B", :i2, revocation_epoch: 2)
    keys = [a, b]

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(signed(keys), nil, view(keys), RegistryHelper.policy(2, epoch: 5))

    assert {:ok, _} =
             Quorum.evaluate(signed(keys), nil, view(keys), RegistryHelper.policy(2, epoch: 9))
  end

  test "policy is fail-closed: bad k, missing audience, unknown tier, non-list" do
    [a] = keys = [RegistryHelper.new_key("A")]
    pairs = signed([a])
    v = view(keys)
    base = RegistryHelper.policy(1)
    assert {:ok, _} = Quorum.evaluate(pairs, nil, v, base)
    assert {:error, :invalid_policy} = Quorum.evaluate(pairs, nil, v, %{base | k: 0})
    assert {:error, :invalid_policy} = Quorum.evaluate(pairs, nil, v, Map.delete(base, :audience))
    assert {:error, :invalid_policy} = Quorum.evaluate(pairs, nil, v, Map.put(base, :tier, :i9))
    assert {:error, :invalid_policy} = Quorum.evaluate(:nope, nil, v, base)

    assert {:error, :quorum_not_met} =
             Quorum.evaluate(pairs, nil, v, Map.put(base, :audience, "other"))

    assert {:error, :quorum_not_met} = Quorum.evaluate([], nil, v, base)
    _ = items([])
  end

  test "from_standings counts distinct custodians among valid standings only" do
    valid = fn kid, c, t -> {:valid, %{kid: kid, custodian_id: c, tier: t, epoch: 0}} end

    assert {:error, :quorum_not_met} =
             Quorum.from_standings([valid.("k1", "c1", :i2), valid.("k2", "c1", :i2)], 2)

    assert {:error, :quorum_not_met} =
             Quorum.from_standings([valid.("k1", "c1", :i2), {:invalid, :bad_signature}], 2)

    assert {:error, :quorum_not_met} = Quorum.from_standings([:ok, :ok], 2)

    assert {:ok, %{custodians: ["c1", "c2"], tier: :i1}} =
             Quorum.from_standings([valid.("k1", "c1", :i2), valid.("k2", "c2", :i1)], 2)

    assert {:error, :quorum_not_met} =
             Quorum.from_standings([valid.("k1", "c1", :i1), valid.("k2", "c2", :i2)], 2, :i2)

    assert {:error, :invalid_policy} = Quorum.from_standings([], 0)
  end

  describe "m < k compromised custodians never reach quorum (exhaustive, n=5 custodians x 2 kids, k=3)" do
    setup do
      custodians = for i <- 1..5, do: "C#{i}"
      keys = for c <- custodians, _ <- 1..2, do: RegistryHelper.new_key(c)
      attacker = RegistryHelper.new_key("attacker-unregistered")
      %{custodians: custodians, keys: keys, attacker: attacker}
    end

    test "every compromised subset of size m < k fails; size >= k succeeds (positive control)",
         %{custodians: custodians, keys: keys, attacker: attacker} do
      v = view(keys)
      k = 3

      subsets =
        for mask <- 0..(Bitwise.bsl(1, 5) - 1) do
          for {c, i} <- Enum.with_index(custodians),
              Bitwise.band(mask, Bitwise.bsl(1, i)) != 0,
              do: c
        end

      for comp <- subsets do
        # the attacker controls every key of a compromised custodian (valid signatures) and
        # forges envelopes for every honest kid with a key it holds (invalid signatures)
        {owned, honest} = Enum.split_with(keys, &(&1.record.custodian_id in comp))
        pairs = signed(owned) ++ Enum.map(honest, &RegistryHelper.approve(&1, %{}, attacker.priv))
        result = Quorum.evaluate(pairs, nil, v, RegistryHelper.policy(k))

        if length(comp) < k do
          assert {:error, :quorum_not_met} = result, "compromised #{inspect(comp)}"
        else
          assert {:ok, %{custodians: cs}} = result
          assert Enum.sort(cs) == Enum.sort(comp)
        end
      end
    end
  end
end
