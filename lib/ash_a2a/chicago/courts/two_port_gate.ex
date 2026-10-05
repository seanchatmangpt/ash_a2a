# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Chicago.Courts.TwoPortGate do
  @moduledoc """
  The algebraic two-port gate (loops-of-loops spec §1 Loop 1) — falsifier
  court `CHI-TWO-PORT`.

  Evidence question: does the gate evaluate all four conjuncts (scope, root,
  clock, signature) unconditionally into a null-mask, admit on null, and
  refuse with exactly the failed bits?

  Every attack runs against real collaborators: a real Ed25519 keypair per
  stimulus, real signed `AshA2A.Authority.Lease`s, the real gate, and — for
  the e2e falsifier — the real `AshA2A.CommandBus` with a real
  `AshA2A.ReceiptStore.Memory`, a real uniquely-named
  `AshA2A.Authority.Broker.InMemory`, and the real MutationHarness Ledger.
  Falsifier map:

    * 001..004 — single-bit tampers (scope/root/clock/signature), each
      signed AFTER tampering so exactly one conjunct is broken: masks
      0x1/0x2/0x4/0x8.
    * 005 — all four broken: mask 0xF.
    * 006 — positive control: the valid signed lease admits.
    * 007 — e2e: the valid lease through the real CommandBus is admitted
      before claim, mints a receipt, and replays it; the `lease_gate`
      boundary telemetry is observed with `outcome=admitted`.
    * 008 — opt-in law: no lease -> the gate is skipped (the `lease_gate`
      activity is never observed) and the run still completes.
    * 009 — branchless witness: the evidence-only `conjunct_hook` is invoked
      exactly four times on BOTH tails (admitted and all-broken 0xF).
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Authority.Lease
  alias AshA2A.Authority.TwoPortGate
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.MutationHarness, as: H
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.Command
  alias AshA2A.SemanticSubject

  @court "CHI-TWO-PORT"
  @boundary "AshA2A.Authority.TwoPortGate.evaluate/3, " <>
              "CommandBus.check_lease_gate/2 before claim_receipt/3"
  @sections ["loops-of-loops §1 Loop 1 (algebraic two-port gate)"]

  @impl true
  def id, do: @court

  @impl true
  def title, do: "The algebraic two-port lease gate"

  @impl true
  def gate, do: 1

  @impl true
  def profile, do: :core

  @impl true
  def rfc_sections, do: @sections

  # --- declarations (§11) ------------------------------------------------------

  @impl true
  def falsifiers do
    [
      neg("001",
        invariant:
          "A lease whose scope digest disagrees with H(scope_of(command)) is refused " <>
            "with exactly mask 0x1 (:lease_scope_mismatch)",
        stimulus: "TwoPortGate.evaluate/3 over a command and a scope-tampered, signed lease",
        boundary: @boundary,
        forbidden_outcome: ":admitted, or a refusal whose mask lacks bit 0x1",
        attempt_evidence: "the real gate evaluated the tampered lease",
        survival_evidence: "mask 0x1 absent, or :admitted on the tampered lease",
        guard: "TwoPortGate scope_failed?/2 -- the conjunct table's 0x1 bit",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      neg("002",
        invariant:
          "A lease whose root digest disagrees with the command's RDFC-1.0 root is " <>
            "refused with exactly mask 0x2 (:lease_root_mismatch)",
        stimulus: "TwoPortGate.evaluate/3 over a command and a root-tampered, signed lease",
        boundary: @boundary,
        forbidden_outcome: ":admitted, or a refusal whose mask lacks bit 0x2",
        attempt_evidence: "the real gate evaluated the tampered lease",
        survival_evidence: "mask 0x2 absent, or :admitted on the tampered lease",
        guard: "TwoPortGate root_failed?/3 -- the conjunct table's 0x2 bit",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      neg("003",
        invariant:
          "A lease whose clock window excludes the captured clock is refused with " <>
            "exactly mask 0x4 (:lease_expired)",
        stimulus:
          "TwoPortGate.evaluate/3 over a command and a cross-VM lease whose persisted " <>
            "wall-clock window lies entirely in the past, correctly signed",
        boundary: @boundary,
        forbidden_outcome: ":admitted, or a refusal whose mask lacks bit 0x4",
        attempt_evidence: "the real gate evaluated the expired lease",
        survival_evidence: "mask 0x4 absent, or :admitted on the expired lease",
        guard:
          "TwoPortGate clock_failed?/3 -- the 0x4 bit; the cross-VM wall-clock " <>
            "fallback of the hybrid clock law",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      neg("004",
        invariant:
          "A lease whose Ed25519 signature does not verify under the authorizing " <>
            "authority's public key is refused with exactly mask 0x8 " <>
            "(:lease_signature_invalid)",
        stimulus: "TwoPortGate.evaluate/3 over a command and a lease with flipped signature bytes",
        boundary: @boundary,
        forbidden_outcome: ":admitted, or a refusal whose mask lacks bit 0x8",
        attempt_evidence: "the real gate evaluated the forged lease",
        survival_evidence: "mask 0x8 absent, or :admitted on the forged lease",
        guard:
          "TwoPortGate signature_failed?/2 -- the 0x8 bit, fail-closed on missing " <>
            "key or signature",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      neg("005",
        invariant:
          "Breaking all four conjuncts refuses with the full mask 0xF -- the piecewise " <>
            "function returns ONE refusal naming every failed conjunct",
        stimulus:
          "TwoPortGate.evaluate/3 over a lease with tampered scope, tampered root, " <>
            "expired window and flipped signature, all at once",
        boundary: @boundary,
        forbidden_outcome: ":admitted, or any mask other than 0xF",
        attempt_evidence: "the real gate evaluated the fully-broken lease",
        survival_evidence: "a mask with any bit clear (a conjunct skipped under accumulation)",
        guard: "the branchless fold over all four conjunct results -- no early exit",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "raised"}}
      ),
      pos("006",
        invariant:
          "The valid signed lease admits: the gate discriminates rather than refusing " <>
            "every lease (§100)",
        stimulus: "TwoPortGate.evaluate/3 over a command and a correctly-signed lease",
        boundary: @boundary,
        attempt_evidence: "the real gate evaluated the valid lease",
        survival_evidence: "the valid lease was refused or the gate raised",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      ),
      pos("007",
        invariant:
          "The valid lease through the real CommandBus is admitted before claim, mints " <>
            "a receipt, and replays the same receipt",
        stimulus:
          "CommandBus.run/4 (opts lease: + lease_public_key:) over the MutationHarness " <>
            "Ledger with a real ReceiptStore.Memory and a real InMemory broker",
        boundary: "AshA2A.CommandBus.run/4 check_lease_gate/2 before claim_receipt/3",
        attempt_evidence: "the lease_gate boundary decided (telemetry observed)",
        survival_evidence:
          "the lease_gate event missing, outcome != admitted, or the receipt absent",
        guard: "CommandBus.run/4 check_lease_gate/2 gates on TwoPortGate.evaluate/3 :admitted",
        failure_class: :identity_failure,
        attempt_predicate: {:observed, "lease_gate", %{"outcome" => "admitted"}},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      ),
      pos("008",
        invariant:
          "Opt-in law: a run with NO lease presented skips the gate entirely -- the " <>
            "command completes and the lease_gate activity is never observed",
        stimulus: "CommandBus.run/4 without opts[:lease] over the same Ledger path",
        boundary: "AshA2A.CommandBus.run/4 check_lease_gate/2 (opt-in skip)",
        attempt_evidence: "the run completed and returned a receipt",
        survival_evidence: "the lease_gate activity IS observed on a lease-less run",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      ),
      pos("009",
        invariant:
          "Branchless witness: the gate invokes the evidence-only conjunct_hook exactly " <>
            "four times on BOTH tails -- the admitted path and the all-broken 0xF path",
        stimulus:
          "TwoPortGate.evaluate/3 with conjunct_hook attached, over a valid lease and " <>
            "over the all-broken lease",
        boundary: "AshA2A.Authority.TwoPortGate.evaluate/3 conjunct_hook fold",
        attempt_evidence: "both gate stimuli ran and returned",
        survival_evidence:
          "fewer than four hook invocations on either tail (a short-circuit " <>
            "evaluation order)",
        attempt_predicate: {:observed, "chicago.stimulus.start"},
        outcome_predicate: {:observed, "chicago.stimulus.stop", %{"outcome" => "returned"}}
      )
    ]
  end

  defp neg(n, fields) do
    Falsifier.new!(
      [
        id: "#{@court}-#{n}",
        court_id: @court,
        kind: :negative,
        rfc_sections: @sections
      ]
      |> Keyword.merge(fields)
    )
  end

  defp pos(n, fields),
    do:
      Falsifier.new!(
        [id: "#{@court}-#{n}", court_id: @court, kind: :positive_control]
        |> Keyword.merge(fields)
      )

  # --- OCEL mappings (§17) -----------------------------------------------------

  @impl true
  def ocel_mappings do
    [
      Mapping.new!(
        event: [:ash_a2a, :command_bus, :lease_gate],
        activity: "lease_gate",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"command", meta[:command_id], "command"},
            {"capability", meta[:capability_id], "capability"},
            {"principal", meta[:principal_id], "principal"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :mask]) end
      )
    ]
  end

  # --- execution ---------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    f = Map.new(falsifiers(), &{&1.id, &1})
    at = fn n -> Map.fetch!(f, "#{@court}-#{n}") end

    [
      guarded(f["#{@court}-001"], fn -> bit_attack(ctx, at.("001"), :scope) end),
      guarded(f["#{@court}-002"], fn -> bit_attack(ctx, at.("002"), :root) end),
      guarded(f["#{@court}-003"], fn -> bit_attack(ctx, at.("003"), :clock) end),
      guarded(f["#{@court}-004"], fn -> bit_attack(ctx, at.("004"), :signature) end),
      guarded(f["#{@court}-005"], fn -> bit_attack(ctx, at.("005"), :all) end),
      guarded(f["#{@court}-006"], fn -> valid_lease_control(ctx, at.("006")) end),
      guarded(f["#{@court}-007"], fn -> e2e_admission(ctx, at.("007")) end),
      guarded(f["#{@court}-008"], fn -> opt_in_skip(ctx, at.("008")) end),
      guarded(f["#{@court}-009"], fn -> branchless_witness(ctx, at.("009")) end)
    ]
  end

  # One broken edge must not take the other falsifiers with it (§129-§130):
  # a raise becomes UNKNOWN for that falsifier only, never a pass.
  defp guarded(%Falsifier{} = f, fun) do
    fun.()
  rescue
    exception ->
      Result.unknown(f, "raised: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  # --- falsifier bodies --------------------------------------------------------

  # 001-005: one falsifier per tampered conjunct; the tampered lease is
  # signed with the real key AFTER tampering, so exactly the tampered
  # conjunct (and nothing else) is broken. The forbidden outcome is computed
  # from the gate's real return value state-side.
  defp bit_attack(ctx, f, kind) do
    command = gate_command()

    reply =
      try do
        Context.stimulus(ctx, f, fn ->
          {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
          lease = tampered_lease(command, kind, priv)

          case TwoPortGate.evaluate(command, lease, lease_public_key: pub) do
            :admitted ->
              raise "forbidden: tampered lease admitted (#{kind})"

            {:error, {:refused_lease, mask, _codes}} ->
              expected = expected_mask(kind)

              forbidden? =
                if kind == :all do
                  mask != expected
                else
                  Bitwise.band(mask, expected) != expected
                end

              if forbidden?,
                do: raise("forbidden: mask 0x#{Integer.to_string(mask, 16)} wrong for #{kind}"),
                else: {:refused_ok, mask}
          end
        end)
      rescue
        exception -> {:forbidden_raised, Exception.message(exception)}
      end

    forbidden? = match?({:forbidden_raised, _}, reply)

    Result.negative(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      forbidden_outcome_observed?: forbidden?,
      evidence: %{
        "kind" => Atom.to_string(kind),
        "reply" => inspect(reply)
      }
    )
  end

  # 006
  defp valid_lease_control(ctx, f) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    command = gate_command()

    reply =
      Context.stimulus(ctx, f, fn ->
        command
        |> Lease.for_command()
        |> Lease.sign(priv)
        |> then(fn {:ok, signed} -> signed end)
        |> then(&TwoPortGate.evaluate(command, &1, lease_public_key: pub))
      end)

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      expected_outcome_observed?: reply == :admitted,
      evidence: %{"reply" => inspect(reply)}
    )
  end

  # 007
  defp e2e_admission(ctx, f) do
    label = H.unique("chi-two-port-e2e")

    H.with_store(fn store ->
      H.with_broker(fn broker ->
        principal = H.principal()
        authority = H.granted_authority(broker, principal)
        command = H.command(label, authority: authority, principal: principal)

        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

        lease =
          command
          |> Lease.for_command()
          |> Lease.sign(priv)
          |> then(fn {:ok, signed} -> signed end)

        reply =
          Context.stimulus(ctx, f, fn ->
            {:ok, first} = H.run(command, label, store, lease: lease, lease_public_key: pub)
            {:ok, replay} = H.run(command, label, store, lease: lease, lease_public_key: pub)
            {first.receipt_id, replay.receipt_id, replay.replayed?}
          end)

        Result.positive(f,
          attempt_observed?: Context.observed?(ctx, f, "lease_gate"),
          expected_outcome_observed?:
            match?({id, id, true}, reply) and
              lease_gate_admitted?(ctx, f),
          evidence: %{"label" => label, "reply" => inspect(reply)}
        )
      end)
    end)
  end

  # 008
  defp opt_in_skip(ctx, f) do
    label = H.unique("chi-two-port-skip")

    H.with_store(fn store ->
      H.with_broker(fn broker ->
        authority = H.granted_authority(broker, H.principal())

        reply =
          Context.stimulus(ctx, f, fn ->
            command = H.command(label, authority: authority, principal: H.principal())
            H.run(command, label, store, [])
          end)

        Result.positive(f,
          attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
          expected_outcome_observed?:
            match?({:ok, %{receipt_id: _}}, reply) and
              not lease_gate_observed?(ctx, f),
          evidence: %{
            "label" => label,
            "reply" => reply_summary(reply),
            "lease_gate_observed?" => lease_gate_observed?(ctx, f)
          }
        )
      end)
    end)
  end

  # 009
  defp branchless_witness(ctx, f) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    command = gate_command()

    hook = fn name, failed? -> send(self(), {:conjunct, name, failed?}) end
    drain = fn -> drain_conjuncts([]) end

    reply =
      Context.stimulus(ctx, f, fn ->
        valid =
          command
          |> Lease.for_command()
          |> Lease.sign(priv)
          |> then(fn {:ok, signed} -> signed end)

        admitted = TwoPortGate.evaluate(command, valid, lease_public_key: pub, conjunct_hook: hook)
        admitted_calls = drain.()

        {pub2, priv2} = :crypto.generate_key(:eddsa, :ed25519)

        broken = tampered_lease(command, :all, priv2)

        refused = TwoPortGate.evaluate(command, broken, lease_public_key: pub2, conjunct_hook: hook)
        refused_calls = drain.()

        {admitted, admitted_calls, refused, refused_calls}
      end)

    {admitted, admitted_calls, refused, refused_calls} = reply

    Result.positive(f,
      attempt_observed?: Context.observed?(ctx, f, "chicago.stimulus.start"),
      expected_outcome_observed?:
        admitted == :admitted and
          match?({:error, {:refused_lease, 0xF, _}}, refused) and
          length(admitted_calls) == 4 and length(refused_calls) == 4,
      evidence: %{
        "admitted" => inspect(admitted),
        "refused" => inspect(refused),
        "admitted_tail_calls" => inspect(admitted_calls),
        "refused_tail_calls" => inspect(refused_calls)
      }
    )
  end

  # --- shared real-collaborator builders ---------------------------------------

  @ga "sha256:" <> String.duplicate("a", 64)
  @gb "sha256:" <> String.duplicate("b", 64)
  @gc "sha256:" <> String.duplicate("c", 64)

  defp subject do
    {:ok, subject} =
      SemanticSubject.new(
        graph_digest: @ga,
        projection_digest: @gb,
        manufacturer_digest: @gc,
        ephemeral?: false
      )

    subject
  end

  defp gate_command do
    Command.new(H.capability(),
      command_id: H.unique("chi-two-port"),
      agent_id: "chi-two-port-agent",
      principal_id: H.principal(),
      task_id: H.unique("chi-two-port-task"),
      semantic_subject: subject(),
      input: %{label: H.unique("chi-two-port-input")},
      metadata: %{candidate_digest: "sha256:chi-two-port-candidate"}
    )
  end

  # Builds the lease for `kind`, tampering exactly the conjunct(s) the kind
  # names, THEN signing with a real key, so exactly the tampered conjunct(s)
  # is/are broken and the signature conjunct itself is sound.
  defp tampered_lease(command, kind, priv) do
    lease = Lease.for_command(command)

    lease =
      case kind do
        :scope -> %{lease | scope_digest: "sha256:" <> String.duplicate("d", 64)}
        :root -> %{lease | root_digest: "sha256:" <> String.duplicate("e", 64)}
        :clock ->
          %{
            lease
            | issued_monotonic_ms: nil,
              not_before: ~U[2020-01-01 00:00:00Z],
              expires_at: ~U[2020-01-02 00:00:00Z]
          }
        :signature -> lease
        :all ->
          %{
            lease
            | scope_digest: "sha256:" <> String.duplicate("d", 64),
              root_digest: "sha256:" <> String.duplicate("e", 64),
              issued_monotonic_ms: nil,
              not_before: ~U[2020-01-01 00:00:00Z],
              expires_at: ~U[2020-01-02 00:00:00Z]
          }
      end

    # :signature and :all break the signature too: one byte flipped on an
    # otherwise-valid signature (framing intact, verify fails).
    {:ok, signed} = Lease.sign(lease, priv)

    if kind in [:signature, :all],
      do: flip_signature_byte(signed),
      else: signed
  end

  defp flip_signature_byte(%Lease{signature: <<b, rest::binary>>} = lease) do
    %{lease | signature: <<Bitwise.bxor(b, 1), rest::binary>>}
  end

  defp lease_gate_admitted?(ctx, f) do
    # Re-reads the real lease_gate records attributed to this falsifier: the
    # positive verdict fails when the boundary ran but refused.
    ctx.observer
    |> AshA2A.Chicago.Observer.records_for(f.id)
    |> Enum.any?(&(&1.activity == "lease_gate" and &1.attributes["outcome"] == "admitted"))
  end

  # 008 uses the same re-read: skip means NO lease_gate record at all.
  defp lease_gate_observed?(ctx, f) do
    ctx.observer
    |> AshA2A.Chicago.Observer.records_for(f.id)
    |> Enum.any?(&(&1.activity == "lease_gate"))
  end

  defp expected_mask(:scope), do: 0x1
  defp expected_mask(:root), do: 0x2
  defp expected_mask(:clock), do: 0x4
  defp expected_mask(:signature), do: 0x8
  defp expected_mask(:all), do: 0xF

  defp drain_conjuncts(acc) do
    receive do
      {:conjunct, name, failed?} -> drain_conjuncts([{name, failed?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reply_summary({:ok, receipt}), do: {:ok, receipt.receipt_id}
  defp reply_summary({:error, reason}), do: {:error, inspect(reason)}
end
