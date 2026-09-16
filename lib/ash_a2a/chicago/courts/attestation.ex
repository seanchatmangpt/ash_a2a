defmodule AshA2A.Chicago.Courts.Attestation do
  @moduledoc """
  Attestation Court and Evidence Classes (RFC-SA2A-002 §24, §72, §100).

  Invariant: an attestation never claims more than was observed.

      LocalTest ≠ HostedCI ≠ Deployment ≠ RuntimeObservation ≠ Publication ≠ Merge

  The SUT names these classes `AshA2A.Evidence.LocalTest`, `HostedCI`,
  `Production` (deployment), `RuntimeAlive` (runtime observation),
  `Publication`, `Merge`. Every stimulus drives the real
  `AshA2A.Evidence.Class.promote/3` / `assert_at_least/2` or the real
  `AshA2A.Semantic.Attestation.from_receipts/2` / `verify/2` over receipts the
  real `AshA2A.CommandBus.run/4` produced. Class values a stimulus starts from
  are earned by genuine promotions *before* the stimulus, so the only
  promotion attributed to a stimulus is the attack.

  Attempt evidence is the boundary decision event (`evidence.promote`,
  `evidence.assert`, `attestation.build`, `attestation.verify`) whatever its
  outcome -- a deleted guard makes the falsifier survive (§11, §22).

  Falsifiers:

    * `SA2A-ATTEST-001..005` -- each adjacent promotion without new evidence
    * `SA2A-ATTEST-006` -- non-adjacent promotion (local test -> merge)
    * `SA2A-ATTEST-007` -- an unearned strong class satisfies a read-side guard
    * `SA2A-ATTEST-008` -- an earned weaker class satisfies a stronger requirement
    * `SA2A-ATTEST-009` -- an attestation carries an evidence class its receipts never carried
    * `SA2A-ATTEST-010` -- an attestation claims a keyed receipt binding never observed
    * `SA2A-ATTEST-011` -- an attestation over a tampered receipt
    * `SA2A-ATTEST-012` -- an attestation over an unbound receipt claims a binding
    * `SA2A-ATTEST-013`, `-014` -- positive controls (§100)
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.ReceiptBindingAttestation, as: Fx
  alias AshA2A.Evidence.{Class, HostedCI, LocalTest, Merge, Production, Publication, RuntimeAlive}
  alias AshA2A.Semantic.Attestation

  @court "SA2A-ATTEST"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Attestation court / evidence classes"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§24", "§72", "§100"]

  @impl true
  def ocel_mappings, do: Fx.mappings()

  # {n, from, to, attack, description}
  @promotions [
    {"001", LocalTest, HostedCI, :same_basis,
     "local test -> hosted CI re-presenting the local test's own basis"},
    {"002", HostedCI, Production, :empty_basis, "hosted CI -> deployment with an empty basis"},
    {"003", Production, RuntimeAlive, :replay_earlier,
     "deployment -> runtime observation replaying the hosted CI evidence spent earlier in the chain"},
    {"004", RuntimeAlive, Publication, :same_basis,
     "runtime observation -> publication re-presenting the runtime observation's own basis"},
    {"005", Publication, Merge, :replay_root,
     "publication -> merge replaying the root local test evidence"}
  ]

  @chain_bases [
    {HostedCI, %{job: "ci-attest"}},
    {Production, %{deploy: "deploy-attest"}},
    {RuntimeAlive, %{probe: "probe-attest"}},
    {Publication, %{release: "release-attest"}},
    {Merge, %{pr: "pr-attest"}}
  ]

  @root_basis %{suite: "mix test", run: "attest"}

  defp promote_attempt(from, to),
    do: {:observed, "evidence.promote", %{"from" => label(from), "to" => label(to)}}

  defp promoted(to),
    do: {:observed, "evidence.promote", %{"to" => label(to), "outcome" => "promoted"}}

  defp label(class), do: class |> Class.label() |> Atom.to_string()

  @impl true
  def falsifiers do
    promotion_falsifiers() ++ class_falsifiers() ++ attestation_falsifiers() ++ controls()
  end

  defp promotion_falsifiers do
    for {n, from, to, _attack, description} <- @promotions do
      Falsifier.new!(
        id: "#{@court}-#{n}",
        court_id: @court,
        kind: :negative,
        invariant:
          "#{from.label()} evidence is never promoted to #{to.label()} without genuinely new evidence (§24, §72)",
        stimulus: "Evidence.Class.promote/3: #{description}",
        boundary: "AshA2A.Evidence.Class.promote/3",
        forbidden_outcome: "evidence.promote to=#{to.label()} outcome=promoted",
        attempt_evidence:
          "evidence.promote from=#{from.label()} to=#{to.label()} observed (any outcome) AND the starting value is an earned #{from.label()} (verify_chain :ok)",
        survival_evidence:
          "evidence.promote outcome=promoted in OCEL, or {:ok, %#{inspect(to)}{}} returned",
        guard:
          "Evidence.Class.promote_verified/4 (empty basis, same basis, consumed-evidence replay)",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§24", "§72"],
        attempt_predicate: promote_attempt(from, to),
        outcome_predicate: promoted(to)
      )
    end
  end

  defp class_falsifiers do
    [
      Falsifier.new!(
        id: "#{@court}-006",
        court_id: @court,
        kind: :negative,
        invariant: "Local test evidence never skips the chain straight to merge (§72)",
        stimulus:
          "Evidence.Class.promote(earned LocalTest, Merge, genuinely new basis) -- non-adjacent",
        boundary: "AshA2A.Evidence.Class.promote/3 adjacency",
        forbidden_outcome: "evidence.promote to=merge outcome=promoted",
        attempt_evidence: "evidence.promote from=local_test to=merge observed",
        survival_evidence: "evidence.promote outcome=promoted, or {:ok, %Merge{}} returned",
        guard: "Evidence.Class.promote/3 next(from) == {:ok, target}",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§72"],
        attempt_predicate: promote_attempt(LocalTest, Merge),
        outcome_predicate: promoted(Merge)
      ),
      Falsifier.new!(
        id: "#{@court}-007",
        court_id: @court,
        kind: :negative,
        invariant:
          "A merge-class value not earned by promotion never satisfies a merge requirement (§24, §72)",
        stimulus:
          "Evidence.Class.assert_at_least(v, Merge) for v = Merge.new/1 (unlinked root) and a hand-built %Merge{} with a made-up chain digest",
        boundary: "AshA2A.Evidence.Class.assert_at_least/2",
        forbidden_outcome: "evidence.assert to=merge outcome=admitted",
        attempt_evidence: "two evidence.assert from=merge to=merge observed",
        survival_evidence: "evidence.assert outcome=admitted, or :ok returned",
        guard: "Evidence.Class.assert_at_least/2 verify_chain/1",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§24", "§72"],
        attempt_predicate:
          {:all,
           [
             {:observed, "evidence.assert", %{"from" => "merge", "to" => "merge"}},
             {:count, "evidence.assert", :gte, 2}
           ]},
        outcome_predicate: {:observed, "evidence.assert", %{"outcome" => "admitted"}}
      ),
      Falsifier.new!(
        id: "#{@court}-008",
        court_id: @court,
        kind: :negative,
        invariant:
          "Evidence classes stay distinct: an earned weaker class never satisfies the next class's requirement (§24)",
        stimulus:
          "assert_at_least(earned HostedCI, Production), (earned Production, RuntimeAlive), (earned RuntimeAlive, Publication), (earned Publication, Merge)",
        boundary: "AshA2A.Evidence.Class.assert_at_least/2 rank check",
        forbidden_outcome: "evidence.assert outcome=admitted",
        attempt_evidence: "four evidence.assert observed, each from an earned class",
        survival_evidence: "evidence.assert outcome=admitted, or :ok returned",
        guard: "Evidence.Class.assert_at_least/2 rank(from) >= rank(required)",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§24"],
        attempt_predicate: {:count, "evidence.assert", :gte, 4},
        outcome_predicate: {:observed, "evidence.assert", %{"outcome" => "admitted"}}
      )
    ]
  end

  defp attestation_falsifiers do
    [
      Falsifier.new!(
        id: "#{@court}-009",
        court_id: @court,
        kind: :negative,
        invariant:
          "An attestation never carries an evidence class stronger than its receipts observed, even one genuinely earned elsewhere (§72)",
        stimulus:
          "Attestation.from_receipts/1 over a real CommandBus receipt (local_test), edited to carry an earned Merge chain from an unrelated promotion; Attestation.verify/2",
        boundary: "AshA2A.Semantic.Attestation.verify/2",
        forbidden_outcome: "attestation.verify outcome=verified",
        attempt_evidence:
          "attestation.verify observed AND the edited attestation's class is merge while the receipt's is local_test",
        survival_evidence: "attestation.verify outcome=verified, or :ok returned",
        guard:
          "Attestation.verify/2 evidence_class_backed/2 (claimed class == class rebuilt from the receipts)",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§72"],
        attempt_predicate: {:observed, "attestation.verify"},
        outcome_predicate: {:observed, "attestation.verify", %{"outcome" => "verified"}}
      ),
      Falsifier.new!(
        id: "#{@court}-010",
        court_id: @court,
        kind: :negative,
        invariant:
          "An attestation never claims a keyed receipt binding that was not observed (§40, §72)",
        stimulus:
          "Attestation over a real unkeyed CommandBus receipt, edited to claim receipt_binding.keyed=true; Attestation.verify/2",
        boundary: "AshA2A.Semantic.Attestation.verify/2",
        forbidden_outcome: "attestation.verify outcome=verified",
        attempt_evidence:
          "attestation.verify observed AND the receipt's binding is keyed=false while the edited claim says keyed=true",
        survival_evidence: "attestation.verify outcome=verified, or :ok returned",
        guard: "Attestation.verify/2 no_unbacked_claims/2 over :receipt_binding",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§72"],
        attempt_predicate: {:observed, "attestation.verify"},
        outcome_predicate: {:observed, "attestation.verify", %{"outcome" => "verified"}}
      ),
      Falsifier.new!(
        id: "#{@court}-011",
        court_id: @court,
        kind: :negative,
        invariant: "A tampered receipt never supports an attestation (§40, §72)",
        stimulus:
          "Real CommandBus receipt with its plan_digest rewritten; Attestation.from_receipts/1 over it, and Attestation.verify/2 of the honest attestation against it",
        boundary:
          "AshA2A.Semantic.Attestation.from_receipts/2 + verify/2 (receipt binding verification)",
        forbidden_outcome:
          "attestation.build outcome=built or attestation.verify outcome=verified",
        attempt_evidence:
          "attestation.build and attestation.verify observed AND the receipt's plan_digest really differs from the executed one",
        survival_evidence: "built or verified in OCEL, or {:ok, _} / :ok returned",
        guard: "Attestation receipt_binding/1 -> Receipt.Binding.verify/2",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§72"],
        attempt_predicate:
          {:all, [{:observed, "attestation.build"}, {:observed, "attestation.verify"}]},
        outcome_predicate:
          {:any,
           [
             {:observed, "attestation.build", %{"outcome" => "built"}},
             {:observed, "attestation.verify", %{"outcome" => "verified"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-012",
        court_id: @court,
        kind: :negative,
        invariant:
          "An attestation over a receipt whose binding was stripped leaves the binding unclaimed (§72: refused or unclaimed)",
        stimulus: "Real CommandBus receipt with binding: nil; Attestation.from_receipts/1",
        boundary: "AshA2A.Semantic.Attestation.from_receipts/2",
        forbidden_outcome: "attestation.build receipt_binding=claimed",
        attempt_evidence: "attestation.build observed AND the receipt really carries no binding",
        survival_evidence:
          "attestation.build receipt_binding=claimed in OCEL, or Attestation.claims?(a, :receipt_binding)",
        guard:
          "Attestation receipt_binding/1 (claimed only when every receipt is bound and verifies)",
        failure_class: :receipt_failure,
        rfc_sections: ["§72"],
        attempt_predicate: {:observed, "attestation.build"},
        outcome_predicate: {:observed, "attestation.build", %{"receipt_binding" => "claimed"}}
      )
    ]
  end

  defp controls do
    [
      Falsifier.new!(
        id: "#{@court}-013",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "Genuinely new evidence at every step climbs the whole chain and satisfies merge (§100)",
        stimulus:
          "LocalTest.new -> promote to HostedCI, Production, RuntimeAlive, Publication, Merge with a distinct basis each; assert_at_least(merge, Merge)",
        boundary: "AshA2A.Evidence.Class.promote/3 + assert_at_least/2",
        attempt_evidence: "evidence.promote observed",
        survival_evidence:
          "five evidence.promote outcome=promoted, no refusal, evidence.assert to=merge outcome=admitted",
        failure_class: :meta_admission_failure,
        rfc_sections: ["§24", "§100"],
        attempt_predicate: {:observed, "evidence.promote"},
        outcome_predicate:
          {:all,
           [
             {:count, "evidence.promote", :eq, 5},
             {:not_observed, "evidence.promote", %{"outcome" => "refused"}},
             {:observed, "evidence.assert", %{"to" => "merge", "outcome" => "admitted"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-014",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An honest attestation over real receipts is built and verifies, claiming exactly the observed binding and class (§72, §100)",
        stimulus:
          "Attestation.from_receipts/1 over a real CommandBus receipt read back from the store; Attestation.verify/2",
        boundary: "AshA2A.Semantic.Attestation.from_receipts/2 + verify/2",
        attempt_evidence: "attestation.build observed",
        survival_evidence:
          "attestation.build built receipt_binding=claimed evidence_class=local_test binding_keyed=false, attestation.verify verified",
        failure_class: :receipt_failure,
        rfc_sections: ["§72", "§100"],
        attempt_predicate: {:observed, "attestation.build"},
        outcome_predicate:
          {:all,
           [
             {:observed, "attestation.build",
              %{
                "outcome" => "built",
                "receipt_binding" => "claimed",
                "binding_keyed" => "false",
                "evidence_class" => "local_test"
              }},
             {:observed, "attestation.verify", %{"outcome" => "verified"}}
           ]}
      )
    ]
  end

  # --- run ------------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    by_id = Map.new(falsifiers(), &{&1.id, &1})
    f = &Map.fetch!(by_id, "#{@court}-" <> &1)
    chain = earned_chain()

    Fx.with_key(nil, fn ->
      Fx.with_store(fn store_opts ->
        receipt = Fx.execute("attest", :honest_write, store_opts).receipt

        for {n, from, to, attack, _} <- @promotions do
          promotion_attack(ctx, f.(n), Map.fetch!(chain, from), to, attack, chain)
        end ++
          [
            skip(ctx, f.("006"), chain),
            unearned(ctx, f.("007")),
            distinct(ctx, f.("008"), chain),
            class_overclaim(ctx, f.("009"), receipt, chain),
            keyed_overclaim(ctx, f.("010"), receipt),
            tampered(ctx, f.("011"), receipt),
            unbound(ctx, f.("012"), receipt),
            full_chain(ctx, f.("013")),
            honest(ctx, f.("014"), receipt)
          ]
      end)
    end)
  end

  # Genuine promotions, outside every stimulus.
  defp earned_chain do
    root = LocalTest.new(@root_basis)

    {chain, _last} =
      Enum.reduce(@chain_bases, {%{LocalTest => root}, root}, fn {target, basis},
                                                                 {acc, current} ->
        {:ok, next} = Class.promote(current, target, basis)
        {Map.put(acc, target, next), next}
      end)

    chain
  end

  defp promotion_attack(ctx, f, current, target, attack, _chain) do
    basis =
      case attack do
        :same_basis -> current.basis
        :empty_basis -> %{}
        :replay_earlier -> %{job: "ci-attest"}
        :replay_root -> @root_basis
      end

    result = Context.stimulus(ctx, f, fn -> Class.promote(current, target, basis) end)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "evidence.promote", %{"from" => label(current), "to" => label(target)}) and
          Class.verify_chain(current) == :ok,
      forbidden_outcome_observed?:
        match?({:ok, _}, result) or
          observed?(ctx, f, "evidence.promote", %{"outcome" => "promoted"}),
      evidence: %{"result" => summary(result), "attack" => Atom.to_string(attack)}
    )
  end

  defp skip(ctx, f, chain) do
    local = Map.fetch!(chain, LocalTest)
    result = Context.stimulus(ctx, f, fn -> Class.promote(local, Merge, %{pr: "skip"}) end)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "evidence.promote", %{"from" => "local_test", "to" => "merge"}),
      forbidden_outcome_observed?:
        match?({:ok, _}, result) or
          observed?(ctx, f, "evidence.promote", %{"outcome" => "promoted"}),
      evidence: %{"result" => summary(result)}
    )
  end

  defp unearned(ctx, f) do
    forged = [
      Merge.new(%{pr: "forged"}),
      %Merge{
        evidence_digest: Class.digest(%{pr: "forged"}),
        observed_at: DateTime.utc_now(),
        chain_digest: "sha256:made-up"
      }
    ]

    results =
      Context.stimulus(ctx, f, fn -> Enum.map(forged, &Class.assert_at_least(&1, Merge)) end)

    Result.negative(f,
      attempt_observed?:
        count(ctx, f, "evidence.assert", %{"from" => "merge", "to" => "merge"}) >= 2 and
          Enum.all?(forged, &match?({:error, _}, Class.verify_chain(&1))),
      forbidden_outcome_observed?:
        Enum.any?(results, &(&1 == :ok)) or
          observed?(ctx, f, "evidence.assert", %{"outcome" => "admitted"}),
      evidence: %{"results" => Enum.map(results, &summary/1)}
    )
  end

  defp distinct(ctx, f, chain) do
    pairs = [
      {HostedCI, Production},
      {Production, RuntimeAlive},
      {RuntimeAlive, Publication},
      {Publication, Merge}
    ]

    results =
      Context.stimulus(ctx, f, fn ->
        Enum.map(pairs, fn {have, required} ->
          Class.assert_at_least(Map.fetch!(chain, have), required)
        end)
      end)

    Result.negative(f,
      attempt_observed?:
        count(ctx, f, "evidence.assert", %{}) >= 4 and
          Enum.all?(pairs, fn {have, _} -> Class.verify_chain(Map.fetch!(chain, have)) == :ok end),
      forbidden_outcome_observed?:
        Enum.any?(results, &(&1 == :ok)) or
          observed?(ctx, f, "evidence.assert", %{"outcome" => "admitted"}),
      evidence: %{"results" => Enum.map(results, &summary/1)}
    )
  end

  defp class_overclaim(_ctx, f, nil, _chain), do: Result.unknown(f, "no stored receipt")

  defp class_overclaim(ctx, f, receipt, chain) do
    {:ok, honest} = Attestation.from_receipts([receipt])
    edited = %{honest | evidence_class: Map.fetch!(chain, Merge)}
    result = Context.stimulus(ctx, f, fn -> Attestation.verify(edited, [receipt]) end)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "attestation.verify", %{}) and
          Class.label(edited.evidence_class) == :merge and
          Class.label(receipt.evidence_class) == :local_test,
      forbidden_outcome_observed?:
        result == :ok or observed?(ctx, f, "attestation.verify", %{"outcome" => "verified"}),
      evidence: %{"result" => summary(result)}
    )
  end

  defp keyed_overclaim(_ctx, f, nil), do: Result.unknown(f, "no stored receipt")

  defp keyed_overclaim(ctx, f, receipt) do
    {:ok, honest} = Attestation.from_receipts([receipt])
    edited = %{honest | receipt_binding: %{honest.receipt_binding | keyed: true}}
    result = Context.stimulus(ctx, f, fn -> Attestation.verify(edited, [receipt]) end)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "attestation.verify", %{}) and receipt.binding.keyed == false and
          edited.receipt_binding.keyed == true,
      forbidden_outcome_observed?:
        result == :ok or observed?(ctx, f, "attestation.verify", %{"outcome" => "verified"}),
      evidence: %{"result" => summary(result)}
    )
  end

  defp tampered(_ctx, f, nil), do: Result.unknown(f, "no stored receipt")

  defp tampered(ctx, f, receipt) do
    {:ok, honest} = Attestation.from_receipts([receipt])
    forged = %{receipt | plan_digest: Fx.sha("a-plan-that-never-ran")}

    {built, verified} =
      Context.stimulus(ctx, f, fn ->
        {Attestation.from_receipts([forged]), Attestation.verify(honest, [forged])}
      end)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "attestation.build", %{}) and
          observed?(ctx, f, "attestation.verify", %{}) and
          forged.plan_digest != receipt.plan_digest,
      forbidden_outcome_observed?:
        match?({:ok, _}, built) or verified == :ok or
          observed?(ctx, f, "attestation.build", %{"outcome" => "built"}) or
          observed?(ctx, f, "attestation.verify", %{"outcome" => "verified"}),
      evidence: %{"built" => summary(built), "verified" => summary(verified)}
    )
  end

  defp unbound(_ctx, f, nil), do: Result.unknown(f, "no stored receipt")

  defp unbound(ctx, f, receipt) do
    stripped = %{receipt | binding: nil}
    result = Context.stimulus(ctx, f, fn -> Attestation.from_receipts([stripped]) end)

    claimed =
      case result do
        {:ok, attestation} -> Attestation.claims?(attestation, :receipt_binding)
        {:error, _} -> false
      end

    Result.negative(f,
      attempt_observed?: observed?(ctx, f, "attestation.build", %{}) and is_nil(stripped.binding),
      forbidden_outcome_observed?:
        claimed or observed?(ctx, f, "attestation.build", %{"receipt_binding" => "claimed"}),
      evidence: %{"result" => summary(result)}
    )
  end

  defp full_chain(ctx, f) do
    {final, admitted} =
      Context.stimulus(ctx, f, fn ->
        final =
          Enum.reduce_while(
            pc_bases(),
            {:ok, LocalTest.new(%{suite: "pc", run: System.unique_integer([:positive])})},
            fn {target, basis}, {:ok, current} ->
              case Class.promote(current, target, basis) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end
            end
          )

        admitted =
          case final do
            {:ok, merge} -> Class.assert_at_least(merge, Merge)
            error -> error
          end

        {final, admitted}
      end)

    Result.positive(f,
      attempt_observed?: observed?(ctx, f, "evidence.promote", %{}),
      expected_outcome_observed?:
        match?({:ok, %Merge{}}, final) and admitted == :ok and
          count(ctx, f, "evidence.promote", %{"outcome" => "promoted"}) == 5,
      evidence: %{"final" => summary(final), "admitted" => summary(admitted)}
    )
  end

  defp pc_bases do
    [
      {HostedCI, %{job: "pc-ci"}},
      {Production, %{deploy: "pc-deploy"}},
      {RuntimeAlive, %{probe: "pc-probe"}},
      {Publication, %{release: "pc-release"}},
      {Merge, %{pr: "pc-pr"}}
    ]
  end

  defp honest(_ctx, f, nil), do: Result.unknown(f, "no stored receipt")

  defp honest(ctx, f, receipt) do
    {built, verified} =
      Context.stimulus(ctx, f, fn ->
        built = Attestation.from_receipts([receipt])

        verified =
          case built do
            {:ok, attestation} -> Attestation.verify(attestation, [receipt])
            error -> error
          end

        {built, verified}
      end)

    Result.positive(f,
      attempt_observed?: observed?(ctx, f, "attestation.build", %{}),
      expected_outcome_observed?:
        verified == :ok and
          match?(
            {:ok, %Attestation{receipt_binding: %{keyed: false}, evidence_class: %LocalTest{}}},
            built
          ) and
          observed?(ctx, f, "attestation.build", %{
            "outcome" => "built",
            "receipt_binding" => "claimed"
          }),
      evidence: %{
        "built" => summary(built),
        "verified" => summary(verified),
        "receipt_id" => Identity.external(receipt.receipt_id)
      }
    )
  end

  # --- helpers ----------------------------------------------------------------------

  defp observed?(ctx, f, activity, attrs), do: count(ctx, f, activity, attrs) > 0

  defp count(ctx, f, activity, attrs) do
    ctx
    |> Context.observed(f)
    |> Enum.count(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == v end)
    end)
  end

  defp summary(:ok), do: "ok"
  defp summary({:ok, %Attestation{} = a}), do: "built:unobserved=#{inspect(a.unobserved)}"
  defp summary({:ok, %module{}}), do: "ok:#{module.label()}"

  defp summary({:error, %{code: code, detail: detail}}) when is_atom(detail),
    do: "refused:#{code}:#{detail}"

  defp summary({:error, %{code: code}}), do: "refused:#{code}"
  defp summary(%Receipt{}), do: "receipt"
  defp summary(other), do: inspect(other, limit: 5)
end
