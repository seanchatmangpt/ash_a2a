defmodule AshA2A.UntestedLane18.ConsequenceKernelCodecTest do
  use ExUnit.Case, async: true

  alias AshA2A.ConsequenceKernel.{
    IdentityBundle,
    IdentityGuard,
    IdentityVersion,
    KeyCustody,
    PreparedRecordCodec,
    RefusalCodes
  }

  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.{AuthenticatedRecord, Memory}

  @key String.duplicate("k", 32)

  defp prepared do
    {:ok, ids} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})

    %{
      prepared_digest: "sha256:" <> String.duplicate("a", 64),
      instance: ids,
      authority_epoch: 7,
      consequence_class: :change
    }
  end

  describe "IdentityBundle / IdentityGuard / IdentityVersion" do
    test "bundle is deterministic and passes the guard" do
      {:ok, a} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      {:ok, b} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      assert a == b
      assert :ok = IdentityGuard.admit(a)
    end

    test "bundle changes when any input changes; effect id binds request id" do
      {:ok, a} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 3})
      {:ok, b} = IdentityBundle.build(%{"r" => 9}, %{"e" => 2}, %{"s" => 3})
      {:ok, c} = IdentityBundle.build(%{"r" => 1}, %{"e" => 2}, %{"s" => 4})
      refute a.request_id == b.request_id
      refute a.effect_id == b.effect_id
      assert a.request_id == c.request_id
      refute a.subject_digest == c.subject_digest
    end

    test "bundle refuses unencodable inputs with typed canonical error" do
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{"r" => 1.5}, %{}, %{})
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{}, %{"e" => 0.1}, %{})
      assert {:error, :canonical_float_forbidden} = IdentityBundle.build(%{}, %{}, %{"s" => 2.0})
    end

    test "guard refuses malformed identities" do
      good = "sha256:" <> String.duplicate("0", 64)
      ok = %{request_id: good, effect_id: good, subject_digest: good}
      assert :ok = IdentityGuard.admit(ok)

      for bad <- [
            %{ok | request_id: "sha256:abc"},
            %{ok | effect_id: "md5:" <> String.duplicate("0", 64)},
            %{ok | subject_digest: String.duplicate("0", 64)},
            %{},
            nil
          ] do
        assert {:error, :prepared_record_identity_mismatch} = IdentityGuard.admit(bad)
      end
    end

    test "version admits only current tag" do
      assert :ok = IdentityVersion.admit(IdentityVersion.current())

      assert {:error, :canonical_schema_tag_required} =
               IdentityVersion.admit("sa2a.c1.identity.v0")

      assert {:error, :canonical_schema_tag_required} = IdentityVersion.admit(nil)
    end
  end

  describe "PreparedRecordCodec" do
    test "encode is deterministic canonical JSON containing schema and identity" do
      {:ok, a} = PreparedRecordCodec.encode(prepared())
      {:ok, b} = PreparedRecordCodec.encode(prepared())
      assert a == b
      decoded = Jason.decode!(a)
      assert decoded["schema"] == PreparedRecordCodec.schema()
      assert decoded["authority_epoch"] == 7
      assert decoded["consequence_class"] == "change"
      assert decoded["request_id"] == prepared().instance.request_id
    end

    test "any field change changes the bytes" do
      {:ok, base} = PreparedRecordCodec.encode(prepared())
      {:ok, e1} = PreparedRecordCodec.encode(%{prepared() | authority_epoch: 8})
      {:ok, e2} = PreparedRecordCodec.encode(%{prepared() | consequence_class: :external_do})
      refute base == e1
      refute base == e2
    end
  end

  describe "HmacSha256 + AuthenticatedRecord (real key custody)" do
    test "seal then verify round-trips; record is :prepared with the digest" do
      assert {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)
      assert rec.state == :prepared
      assert rec.digest == prepared().prepared_digest
      assert String.starts_with?(rec.tag, "hmac-sha256:")
      assert :ok = AuthenticatedRecord.verify(rec, HmacSha256, key: @key)
    end

    test "tampered bytes, tampered tag and wrong key are refused" do
      {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(%{rec | bytes: rec.bytes <> " "}, HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(%{rec | tag: "hmac-sha256:00"}, HmacSha256, key: @key)

      assert {:error, :prepared_authentication_failed} =
               AuthenticatedRecord.verify(rec, HmacSha256, key: String.duplicate("z", 32))
    end

    test "short or missing key is unavailable, seal refuses" do
      assert {:error, :prepared_key_unavailable} =
               AuthenticatedRecord.seal(prepared(), HmacSha256, key: "short")

      assert {:error, :prepared_key_unavailable} = KeyCustody.mac(HmacSha256, "x")
    end

    test "sealed record persists in the real Memory store" do
      {:ok, store} = Memory.start_link()
      {:ok, rec} = AuthenticatedRecord.seal(prepared(), HmacSha256, key: @key)
      assert :ok = Memory.put(store, rec)
      assert {:error, :prepared_duplicate} = Memory.put(store, rec)
      {:ok, fetched} = Memory.fetch(store, rec.digest)
      assert :ok = AuthenticatedRecord.verify(fetched, HmacSha256, key: @key)
    end
  end

  describe "RefusalCodes" do
    test "every code classifies and rows/codes/known? agree" do
      assert Enum.sort(RefusalCodes.codes()) == Enum.sort(Map.keys(RefusalCodes.rows()))

      for c <- RefusalCodes.codes() do
        assert RefusalCodes.known?(c)
        assert {:ok, class} = RefusalCodes.classify(c)
        assert class |> Atom.to_string() |> String.starts_with?("blocked_")
      end
    end

    test "specific classes and unknown handling" do
      assert {:ok, :blocked_integrity} = RefusalCodes.classify(:prepared_effect_digest_mismatch)
      assert {:ok, :blocked_architecture} = RefusalCodes.classify(:kernel_bypass)
      assert :error = RefusalCodes.classify(:nope)
      refute RefusalCodes.known?(:nope)
    end

    test "codes emitted by real identity code are all registered" do
      {:error, e1} = IdentityBundle.build(%{"r" => 1.5}, %{}, %{})
      {:error, e2} = IdentityGuard.admit(%{})
      {:error, e3} = IdentityVersion.admit("x")
      for e <- [e1, e2, e3], do: assert(RefusalCodes.known?(e))
    end
  end
end
