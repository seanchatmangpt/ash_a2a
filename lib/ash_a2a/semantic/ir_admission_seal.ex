defmodule AshA2A.Semantic.IrAdmissionSeal do
  @moduledoc """
  RFC-SA2A PRD §13-14 / ARD §12-13 anti-forgery seal for
  `AshA2A.Semantic.IR`, mirroring `AshA2A.Semantic.Standing`'s
  HMAC-SHA256 evidence-chain approach (built for `AshA2A.Semantic.Envelope`)
  for IR's own admitted/candidate boundary.

  ## The gap this closes

  `AshA2A.Semantic.IR` is a bare public struct: `%IR{source_id: "x",
  standing: :admitted, authority: :none, goals: [...]}` is a handful of lines
  any caller can write, exactly the defect class `Standing`'s own moduledoc
  already names for `Envelope` ("a public struct... is three lines any
  caller can write... bypassable"). Every downstream consumer that fences on
  IR (`AshA2A.Semantic.Ontology.from_ir/1`, `AshA2A.Semantic.PlanningIR.
  from_ir/2`, `AshA2A.Semantic.ExecutionPackage.new/6`) previously pattern-
  matched only on `standing: :admitted, authority: :none` -- fields with no
  cryptographic seal, evidence ledger, or history -- so nothing structurally
  distinguished an IR that actually passed `AshA2A.Semantic.Admission.
  admit/2`'s full provenance/grounding/goal/id check chain from a hand-built
  claim. `test/ash_a2a/semantic_execution_package_test.exs`'s own
  `build_admitted_ir/1` helper demonstrated this concretely: it hand-
  constructed an "admitted" IR without ever calling `Admission.admit/2`, and
  `ExecutionPackage.new/6` accepted it.

  `mint/1` mints a seal for an IR that already carries `standing: :admitted,
  authority: :none` (an HMAC-SHA256 over the IR's real content -- source id,
  standing, authority, an admission receipt id, and every admitted item --
  under a per-runtime key held in `:persistent_term`, never serialized,
  never logged). `verify/1` recomputes and constant-time-compares it.
  `AshA2A.Semantic.Admission.admit/2` is the one real call site: it calls
  `mint/1` in its `{:ok, admitted}` success branch, immediately after
  setting `standing: :admitted`, so the seal only ever covers content that
  already passed every check in `Admission.admit/2`'s chain.

  ## What this defends against, precisely (same honesty boundary as `Standing`)

  This closes: struct-literal forgery (an `%IR{standing: :admitted, ...}`
  built by hand, by a test helper, or by any caller that never went through
  `Admission.admit/2`), forgery across the wire, and forgery by replaying a
  serialized/logged IR -- the seal is a plain struct field, never rendered by
  any encoder this codebase ships for IR. It does **not** defend against
  code running in this BEAM that reads the key out of `:persistent_term`,
  redefines this module, or calls `mint/1` directly with content that never
  actually passed `Admission.admit/2` -- an attacker with arbitrary
  in-process code execution has already won by other means, and claiming
  otherwise would be the exact overclaim `Standing`'s own moduledoc already
  refuses to make. The realistic threat this closes is the one the confirmed
  gap actually demonstrated: an ordinary caller -- a test helper, a future
  code path, a sibling module -- constructing an "admitted" IR without
  running the real admission gate.
  """

  alias AshA2A.Semantic.IR

  @seal_key_term {__MODULE__, :seal_key}
  @seal_prefix "hmac-sha256:"

  @type reason :: %{code: atom(), detail: map()}

  @doc """
  Mints an admission receipt id and seal for an IR already at
  `standing: :admitted, authority: :none`, returning the sealed IR.

  Only meaningful when called on an IR that just passed `Admission.admit/2`'s
  full check chain -- called on anything else, it seals whatever content it
  is given, so it is `Admission.admit/2` running its checks first (not this
  function) that makes the resulting seal mean anything. No other module in
  this codebase calls it.
  """
  @spec mint(IR.t()) :: IR.t()
  def mint(%IR{standing: :admitted, authority: :none} = ir) do
    receipt_id = Ash.UUIDv7.generate()
    unsealed = %{ir | admission_receipt_id: receipt_id}
    %{unsealed | admission_seal: seal(unsealed)}
  end

  @doc """
  Verifies that an admitted IR carries a real seal over its own content,
  minted by this runtime, and that an admission receipt id is present.

  Returns `:ok`, or `{:error, %{code: ..., detail: ...}}` naming exactly why:

    * `:semantic_authority_ceiling_violated` -- not even at the admitted/none
      standing this seal is scoped to.
    * `:semantic_ir_unsealed` -- admitted, but no seal/receipt id present at
      all (the hand-built-struct case this module exists to catch).
    * `:semantic_ir_seal_invalid` -- a seal is present but does not match
      this IR's own content under this runtime's key (tampered content, or a
      seal copied from a different IR).
  """
  @spec verify(IR.t()) :: :ok | {:error, reason()}
  def verify(
        %IR{
          standing: :admitted,
          authority: :none,
          admission_seal: seal,
          admission_receipt_id: receipt_id
        } = ir
      )
      when is_binary(seal) and is_binary(receipt_id) do
    if secure_compare(seal, seal(ir)) do
      :ok
    else
      {:error, %{code: :semantic_ir_seal_invalid, detail: %{source_id: ir.source_id}}}
    end
  end

  def verify(%IR{standing: :admitted, authority: :none} = ir) do
    {:error, %{code: :semantic_ir_unsealed, detail: %{source_id: ir.source_id}}}
  end

  def verify(%IR{} = ir) do
    {:error,
     %{
       code: :semantic_authority_ceiling_violated,
       detail: %{standing: ir.standing, authority: ir.authority}
     }}
  end

  defp seal(%IR{} = ir) do
    @seal_prefix <>
      Base.encode16(:crypto.mac(:hmac, :sha256, seal_key(), payload(ir)), case: :lower)
  end

  defp payload(%IR{} = ir) do
    :erlang.term_to_binary(
      {ir.source_id, ir.standing, ir.authority, ir.admission_receipt_id, Enum.sort(IR.items(ir))}
    )
  end

  defp seal_key do
    case :persistent_term.get(@seal_key_term, nil) do
      nil -> seed_key()
      key -> key
    end
  end

  # Seeded under a named global lock so two concurrent first-callers cannot
  # seal under two different keys -- the same pattern `Standing.seed_ledger_key/0`
  # already uses.
  defp seed_key do
    result =
      :global.trans({@seal_key_term, self()}, fn ->
        case :persistent_term.get(@seal_key_term, nil) do
          nil ->
            key = :crypto.strong_rand_bytes(32)
            :persistent_term.put(@seal_key_term, key)
            key

          key ->
            key
        end
      end)

    case result do
      key when is_binary(key) -> key
      :aborted -> :persistent_term.get(@seal_key_term, nil) || seed_key()
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end
end
