defmodule AshA2A.Semantic.RefusalReceiptTest do
  @moduledoc """
  L109 courts for the optional committed refusal receipt
  (`AshA2A.Semantic.Refusal.commit/2` + `receipt/4`).

  Parity provenance: strata-valve-pack `generated/refusals.ex` derivation
  (pack commit 8210f1b24, parity court seam-29-l26 verdict IDENTICAL):
  SHA-256 over `class label <> 0x00 <> term_to_binary({code, stage, subject})`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Semantic.Refusal

  @frame_seed {:frame, <<1, 2, 3>>}

  # Pinned hexes for class "malformed_frame", seed {:frame, <<1, 2, 3>>}.
  # Both computed and cross-checked Elixir-vs-python (hashlib) in this
  # session; the Elixir side is the byte-identical derivation line used by
  # strata-valve-pack's generated Strata.Valve.Refusals.MalformedFrame.
  @frame_ext_hex "83680277056672616d656d00000003010203"
  @frame_receipt_hex "5b67a27a1cce7fb134f3b1d5cda94191ac575fe94de2b174e9e4f17168fa348d"

  describe "determinism" do
    test "same refusal + subject commits the same receipt twice" do
      refusal = Refusal.new(:refused_authority, :authority_required, :authorize)
      subject = {:task, "t-1"}

      committed_a = Refusal.commit(refusal, subject)
      committed_b = Refusal.commit(refusal, subject)

      assert committed_a.receipt == committed_b.receipt
      assert is_binary(committed_a.receipt)
      assert byte_size(committed_a.receipt) == 32
    end

    test "receipt/4 alone is deterministic" do
      a = Refusal.receipt(:refused_identity, :invalid_subject, :identity, "x")
      b = Refusal.receipt(:refused_identity, :invalid_subject, :identity, "x")
      assert a == b
      assert byte_size(a) == 32
    end
  end

  describe "class-distinctness" do
    test "two classes over the same {code, stage, subject} diverge" do
      subject = {:payload, :same}

      a = Refusal.receipt(:refused_authority, :denied, :authorize, subject)
      b = Refusal.receipt(:refused_identity, :denied, :authorize, subject)

      assert a != b
      assert byte_size(a) == 32 and byte_size(b) == 32
    end
  end

  describe "tamper-evidence" do
    test "one-byte change in the subject payload flips the receipt" do
      refusal = Refusal.new(:refused_structure, :bad_term, :parse)
      base = Refusal.commit(refusal, {:frame, <<1, 2, 3>>})
      tampered = Refusal.commit(refusal, {:frame, <<1, 2, 4>>})

      refute base.receipt == tampered.receipt
    end
  end

  describe "cross-impl parity (strata-valve derivation shape)" do
    test "malformed_frame seed {:frame, <<1,2,3>>} matches the pinned strata-valve hex" do
      # The derivation-shape equivalence: this module's receipt/4 hashes
      # `Atom.to_string(:refused_structure)`... but the strata-valve class
      # label is "malformed_frame", so exercise the raw derivation with the
      # exact strata-valve line against the pinned python-verified hex.
      ext = :erlang.term_to_binary(@frame_seed)
      assert Base.encode16(ext) == String.upcase(@frame_ext_hex)

      raw = :crypto.hash(:sha256, "malformed_frame" <> <<0>> <> ext)
      assert Base.encode16(raw) == String.upcase(@frame_receipt_hex)

      # Same derivation through the module seam: the class label of the
      # strata-valve class is what the parity court pins, so assert the
      # module's derivation over the same label via receipt/4's structure
      # (label <> 0 <> ext-of-{code, stage, subject}) using matching atoms.
      via_module =
        Refusal.receipt(:refused_structure, :frame, :strata_valve_parity, @frame_seed)

      assert byte_size(via_module) == 32
      # Independent reproduction of the same shape with literal label:
      assert via_module ==
               :crypto.hash(
                 :sha256,
                 "refused_structure" <> <<0>> <> :erlang.term_to_binary({:frame, :strata_valve_parity, @frame_seed})
               )
    end
  end

  describe "mint_private wiring" do
    test "incomplete term refusal carries a 32-byte receipt over the refused subject" do
      subject = %{"label" => "only_label"}

      {:error, refusal} = AshA2A.Semantic.Iri.mint_private(subject)

      assert %{code: :private_term_incomplete, receipt: receipt} = refusal
      assert is_binary(receipt) and byte_size(receipt) == 32

      expected =
        Refusal.receipt(
          :refused_namespace,
          :private_term_incomplete,
          :semantic_iri_mint_private,
          subject
        )

      assert receipt == expected
    end

    test "receipt is deterministic per subject and diverges per subject" do
      {:error, a} = AshA2A.Semantic.Iri.mint_private(%{"label" => "x"})
      {:error, b} = AshA2A.Semantic.Iri.mint_private(%{"label" => "x"})
      {:error, c} = AshA2A.Semantic.Iri.mint_private(%{"label" => "y"})

      assert a.receipt == b.receipt
      assert a.receipt != c.receipt
    end
  end

  describe "to_map additive receipt" do
    test "nil receipt serializes as nil; committed receipt serializes as uppercase hex" do
      base = Refusal.new(:refused_bounds, :max_children, :plan)
      assert %{"receipt" => nil} = Refusal.to_map(base)

      committed = Refusal.commit(base, {:child, 7})
      assert %{"receipt" => hex} = Refusal.to_map(committed)
      assert byte_size(Base.decode16!(hex)) == 32
    end
  end

  test "existing constructors stay receipt-free (no breaking change)" do
    r = Refusal.from_error(%{code: :authority_required, detail: "x"}, :authorize)
    assert %Refusal{receipt: nil} = r
    assert r.class == :refused_authority
  end
end
