defmodule AshA2A.Chicago.Courts.ReceiptBinding do
  @moduledoc """
  Gate 9 -- Complete Receipt Identity Binding, and Evidence-Laundering
  Resistance (RFC-SA2A-002 §40, §100, §128, §130).

  Invariant: tampered evidence never retains standing, however the tamper is
  encoded.

      Tampered(receipt) ⇒ ¬Standing(receipt)

  Receipts are produced by the real `AshA2A.CommandBus.run/4` (see
  `AshA2A.Chicago.Fixtures.ReceiptBindingAttestation.execute/3`), read back
  from the real store, written to disk as ETF bytes, tampered at rest, and
  read back from those bytes by the consumer, which asks the real
  `AshA2A.Receipt.Binding.verify/2`. The §128 prohibited-field guard under
  attack is the real `AshA2A.Semantic.Standing.transition/3` S6 inference
  scan.

  Attempt evidence is always the boundary decision event itself, whatever
  its outcome (`receipt.binding.verify`, `receipt.binding.bind`,
  `semantic.standing.transition`), plus the court's own reader confirming the
  tamper is really present in the bytes -- never the guard's refusal, so a
  deleted guard makes the falsifier survive rather than go UNKNOWN (§11, §22).

  Falsifiers:

    * `CHI-RECEIPT-001..012` -- tamper each bound field (§40 list plus
      receipt identity)
    * `CHI-RECEIPT-013..017` -- §128 encodings of a tampered bound field:
      one-level nesting, keyword list, same-content collection swap,
      JSON-style serialization, shadow duplicate key
    * `CHI-RECEIPT-018..021` -- §128 encodings of prohibited `llm_output`
      evidence against the standing guard: nested map, keyword list, pair
      tuples, name-serialization variants
    * `CHI-RECEIPT-022` -- a lawful transition does not reseal a tampered receipt
    * `CHI-RECEIPT-023..025` -- keyed MAC posture: downgrade, unbacked keyed
      claim, consistent re-forge under another key
    * `CHI-RECEIPT-026`, `-027`, `-028`, `-030` -- positive controls (§100)
    * `CHI-RECEIPT-029` -- a result bound only by its prepared anchor refuses
  """

  use AshA2A.Chicago.Court

  alias AshA2A.{Command, Identity, Receipt}
  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.Postcondition, as: Ledgers
  alias AshA2A.Chicago.Fixtures.ReceiptBindingAttestation, as: Fx
  alias AshA2A.Receipt.Binding
  alias AshA2A.Semantic.{Envelope, Standing}

  @court "CHI-RECEIPT"
  @key "chicago-receipt-binding-key-A"
  @attacker_key "chicago-receipt-binding-key-attacker"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Complete receipt identity binding / evidence-laundering resistance"
  @impl true
  def gate, do: 9
  @impl true
  def profile, do: :do
  @impl true
  def rfc_sections, do: ["§40", "§100", "§128", "§130"]

  @impl true
  def ocel_mappings, do: Fx.mappings()

  # §40 bound-field tamper table: {number, bound field, stimulus description}
  @tampers [
    {"001", :actor, "actor rewritten to principal chicago-receipt-mallory"},
    {"002", :semantic_subject, "semantic_subject.graph_digest rewritten"},
    {"003", :capability_action, "capability_id rewritten to Ledger.lying_write"},
    {"004", :input_digest, "input_digest rewritten"},
    {"005", :plan_digest, "plan_digest rewritten"},
    {"006", :projection_digest, "projection_digest rewritten"},
    {"007", :authority_grant, "authority_grant.token_id rewritten"},
    {"008", :idempotency_identity, "idempotency_key rewritten"},
    {"009", :intended_effect, "intended_effect.consequence rewritten :change -> :observe"},
    {"010", :result_identity,
     "a postcondition-contradicted receipt laundered: status -> :completed, postcondition -> verified"},
    {"011", :chain_predecessor,
     "head link predecessor spliced to another real receipt's prepared-anchor digest"},
    {"012", :receipt_identity, "receipt_id swapped for another real receipt's id"}
  ]

  @laundering [
    {"013", "one-level nesting: authority_grant.constraints.scope ledger:write -> admin"},
    {"014",
     "alternate collection: intended_effect as a keyword list carrying consequence :observe"},
    {"015",
     "alternate collection, same pairs: authority_grant re-encoded as a keyword list (Map.to_list/1)"},
    {"016",
     "serialization variation: authority_grant as a JSON-style string-keyed map with a forged token, and actor as its external identity string"},
    {"017",
     "shadow duplicate key: intended_effect carrying :consequence => :change and \"consequence\" => :observe"}
  ]

  @standing_attacks [
    {"018", "%{bundle: %{llm_output: ...}} (one-level nesting)"},
    {"019", "%{bundle: [llm_output: ...]} (keyword list)"},
    {"020", "%{bundle: [{\"llm_output\", ...}], tagged: {:llm_output, ...}} (pair tuples)"},
    {"021",
     "%{\"llmOutput\" => ...} and %{bundle: %{\"LLM-Output\" => ...}} (name serialization)"}
  ]

  # --- predicates ---------------------------------------------------------------

  defp verify_attempted, do: {:observed, "receipt.binding.verify"}
  defp verified, do: {:observed, "receipt.binding.verify", %{"outcome" => "verified"}}

  defp transition_attempted,
    do: {:observed, "semantic.standing.transition", %{"to" => "received"}}

  defp transitioned,
    do: {:observed, "semantic.standing.transition", %{"outcome" => "transitioned"}}

  @impl true
  def falsifiers do
    tamper_falsifiers() ++
      laundering_falsifiers() ++ standing_falsifiers() ++ chain_and_key_falsifiers()
  end

  defp tamper_falsifiers do
    for {n, field, stimulus} <- @tampers do
      Falsifier.new!(
        id: "#{@court}-#{n}",
        court_id: @court,
        kind: :negative,
        invariant: "A receipt whose bound #{field} was tampered never retains standing (§40)",
        stimulus:
          "Real CommandBus receipt read back from the store, persisted as ETF, #{stimulus}, re-read from disk and passed to Receipt.Binding.verify/2",
        boundary: "AshA2A.Receipt.Binding.verify/2",
        forbidden_outcome: "receipt.binding.verify outcome=verified for the tampered receipt",
        attempt_evidence:
          "receipt.binding.verify observed (any outcome) AND the court's own reader finds the tampered #{field} in the bytes on disk differs from the untampered read-back",
        survival_evidence:
          "receipt.binding.verify outcome=verified in OCEL, or {:ok, _} returned for the tampered receipt",
        guard: guard_for(field),
        failure_class: :receipt_failure,
        rfc_sections: ["§40"],
        attempt_predicate: verify_attempted(),
        outcome_predicate: verified()
      )
    end
  end

  defp guard_for(:chain_predecessor),
    do:
      "Receipt.Binding head_matches/3 + chain_intact/3 (link predecessor digested into every link)"

  defp guard_for(field),
    do: "Receipt.Binding field_digests/2 (#{field}) + fields_match/2 + head_matches/3"

  defp laundering_falsifiers do
    for {n, stimulus} <- @laundering do
      Falsifier.new!(
        id: "#{@court}-#{n}",
        court_id: @court,
        kind: :negative,
        invariant:
          "An alternate encoding of a bound field never verifies as the bound evidence: exact-term digests admit no lossy equivalence (§128)",
        stimulus:
          "Real CommandBus receipt persisted as ETF and rewritten at rest -- #{stimulus}; re-read from disk; Receipt.Binding.verify/2",
        boundary: "AshA2A.Receipt.Binding.verify/2",
        forbidden_outcome: "receipt.binding.verify outcome=verified for any re-encoded receipt",
        attempt_evidence:
          "receipt.binding.verify observed AND the court's reader finds the re-encoded field in the bytes on disk",
        survival_evidence: "receipt.binding.verify outcome=verified, or {:ok, _} returned",
        guard:
          "Receipt.Binding field digests over :erlang.term_to_binary(term, [:deterministic]) (injective; no key/collection normalization)",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§128"],
        attempt_predicate: verify_attempted(),
        outcome_predicate: verified()
      )
    end
  end

  defp standing_falsifiers do
    negatives =
      for {n, encoding} <- @standing_attacks do
        Falsifier.new!(
          id: "#{@court}-#{n}",
          court_id: @court,
          kind: :negative,
          invariant:
            "LLM output never acquires standing through a semantically equivalent encoding (§128, RFC-SA2A-001 S6)",
          stimulus:
            "Standing.transition(candidate envelope, :received, transport evidence + #{encoding})",
          boundary: "AshA2A.Semantic.Standing.transition/3 S6 inference scan",
          forbidden_outcome: "semantic.standing.transition outcome=transitioned",
          attempt_evidence:
            "semantic.standing.transition to=received observed (any outcome) AND the court's own normalizing scan finds llm_output in the evidence term",
          survival_evidence:
            "semantic.standing.transition outcome=transitioned in OCEL, or {:ok, %Envelope{standing: :received}} returned",
          guard: "Standing.reject_inference/2 recursive scan_evidence/4",
          failure_class: :meta_admission_failure,
          rfc_sections: ["§128"],
          attempt_predicate: transition_attempted(),
          outcome_predicate: transitioned()
        )
      end

    negatives ++
      [
        Falsifier.new!(
          id: "#{@court}-028",
          court_id: @court,
          kind: :positive_control,
          invariant:
            "The inference scan discriminates: clean evidence with nested keyword lists and pair tuples still earns :received (§100)",
          stimulus:
            "Standing.transition(candidate, :received, %{transport, received_at, bundle: [source: \"bytes\"], pairs: [{\"digest\", ...}]})",
          boundary: "AshA2A.Semantic.Standing.transition/3",
          attempt_evidence: "semantic.standing.transition to=received observed",
          survival_evidence:
            "semantic.standing.transition outcome=transitioned and no refusal; the returned envelope is at :received",
          failure_class: :meta_admission_failure,
          rfc_sections: ["§100", "§128"],
          attempt_predicate: transition_attempted(),
          outcome_predicate:
            {:all,
             [
               transitioned(),
               {:not_observed, "semantic.standing.transition", %{"outcome" => "refused"}}
             ]}
        )
      ]
  end

  defp chain_and_key_falsifiers do
    [
      Falsifier.new!(
        id: "#{@court}-022",
        court_id: @court,
        kind: :negative,
        invariant: "A lawful transition never reseals a tampered receipt (§40)",
        stimulus:
          "Tampered-actor receipt read back from disk, then the real Receipt.reconcile/2 (outbox reconciliation transition), then Receipt.Binding.verify/2",
        boundary: "AshA2A.Receipt.Binding.transition/4 (prior check) + verify/2",
        forbidden_outcome:
          "receipt.binding.bind stage=reconciled outcome=bound, or receipt.binding.verify outcome=verified",
        attempt_evidence:
          "receipt.binding.bind stage=reconciled observed AND receipt.binding.verify observed AND the reconciled receipt still carries the tampered actor",
        survival_evidence: "bind outcome=bound or verify outcome=verified",
        guard: "Receipt.Binding.transition/4 check(prior) before appending a link",
        failure_class: :receipt_failure,
        rfc_sections: ["§40"],
        attempt_predicate:
          {:all,
           [{:observed, "receipt.binding.bind", %{"stage" => "reconciled"}}, verify_attempted()]},
        outcome_predicate:
          {:any,
           [
             {:observed, "receipt.binding.bind",
              %{"stage" => "reconciled", "outcome" => "bound"}},
             verified()
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-023",
        court_id: @court,
        kind: :negative,
        invariant:
          "With a binding key configured, an unkeyed binding re-forged consistently over a tampered receipt never verifies (downgrade, §40)",
        stimulus:
          "Keyed CommandBus receipt; actor tampered; complete unkeyed chain re-forged with the public Binding.bind/2 + transition/4 (key: nil); verify/2 with the key configured",
        boundary: "AshA2A.Receipt.Binding.verify/2 key posture",
        forbidden_outcome: "receipt.binding.verify outcome=verified with key_configured=true",
        attempt_evidence:
          "receipt.binding.verify key_configured=true observed AND the forged binding re-checks as internally consistent under key: nil",
        survival_evidence: "receipt.binding.verify outcome=verified",
        guard: "Receipt.Binding key_posture/2 (:receipt_binding_downgraded)",
        failure_class: :receipt_failure,
        rfc_sections: ["§40"],
        attempt_predicate: {:observed, "receipt.binding.verify", %{"key_configured" => "true"}},
        outcome_predicate: verified()
      ),
      Falsifier.new!(
        id: "#{@court}-024",
        court_id: @court,
        kind: :negative,
        invariant: "An unkeyed binding is never claimed or accepted as keyed (§40)",
        stimulus:
          "Unkeyed CommandBus receipt (no key configured); binding rewritten to keyed: true, algorithm hmac-sha256, a key_id; verify/2 without and with a key configured",
        boundary: "AshA2A.Receipt.Binding.verify/2 keyed-claim check",
        forbidden_outcome:
          "receipt.binding.verify outcome=verified keyed=true, or the SUT bound the unkeyed receipt as keyed",
        attempt_evidence:
          "receipt.binding.verify observed AND receipt.binding.bind for the unkeyed run recorded keyed=false",
        survival_evidence: "receipt.binding.verify outcome=verified keyed=true",
        guard: "Receipt.Binding keyed_claim/1 + key_posture/2",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§130"],
        attempt_predicate: verify_attempted(),
        outcome_predicate:
          {:observed, "receipt.binding.verify", %{"outcome" => "verified", "keyed" => "true"}}
      ),
      Falsifier.new!(
        id: "#{@court}-025",
        court_id: @court,
        kind: :negative,
        invariant:
          "A writer without the key cannot re-forge a keyed binding over a tampered receipt (§40)",
        stimulus:
          "Keyed CommandBus receipt; actor tampered; chain re-forged under an attacker key (a) as-is and (b) relabelled with the real key_id; verify/2 under the real key",
        boundary: "AshA2A.Receipt.Binding.verify/2 HMAC-SHA256 links",
        forbidden_outcome: "receipt.binding.verify outcome=verified",
        attempt_evidence:
          "two receipt.binding.verify key_configured=true observed AND both forgeries re-check under the attacker key",
        survival_evidence: "receipt.binding.verify outcome=verified",
        guard:
          "Receipt.Binding key_posture/2 (:receipt_binding_key_mismatch) + head_matches/3 MAC",
        failure_class: :receipt_failure,
        rfc_sections: ["§40"],
        attempt_predicate: {:count, "receipt.binding.verify", :gte, 2},
        outcome_predicate: verified()
      ),
      Falsifier.new!(
        id: "#{@court}-026",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "An intact receipt verifies: the binding discriminates rather than refusing everything (§100)",
        stimulus:
          "Untampered real CommandBus receipt read back from the store and from its ETF bytes on disk; Receipt.Binding.verify/2 on both (no key configured)",
        boundary: "AshA2A.Receipt.Binding.verify/2",
        attempt_evidence: "receipt.binding.verify observed",
        survival_evidence:
          "receipt.binding.verify outcome=verified keyed=false and no refusal; head stage postcondition chained from the prepared anchor",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§100"],
        attempt_predicate: verify_attempted(),
        outcome_predicate:
          {:all,
           [
             {:observed, "receipt.binding.verify",
              %{"outcome" => "verified", "keyed" => "false"}},
             {:not_observed, "receipt.binding.verify", %{"outcome" => "refused"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-027",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "With a key configured, an intact keyed receipt verifies as keyed, and a lawful transition reseals it (§40, §100)",
        stimulus:
          "Keyed real CommandBus receipt read back from disk; verify/2; Receipt.reconcile/2; verify/2 (key configured)",
        boundary: "AshA2A.Receipt.Binding.verify/2 + transition/4",
        attempt_evidence: "receipt.binding.verify key_configured=true observed",
        survival_evidence:
          "receipt.binding.verify verified keyed=true, bind stage=reconciled outcome=bound, no refusal",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§100"],
        attempt_predicate: {:observed, "receipt.binding.verify", %{"key_configured" => "true"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "receipt.binding.verify", %{"outcome" => "verified", "keyed" => "true"}},
             {:observed, "receipt.binding.bind",
              %{"stage" => "reconciled", "outcome" => "bound"}},
             {:not_observed, "receipt.binding.verify", %{"outcome" => "refused"}}
           ]}
      ),
      Falsifier.new!(
        id: "#{@court}-029",
        court_id: @court,
        kind: :negative,
        invariant:
          "A receipt with an observed result is never bound by its prepared anchor alone (prepared -> final linkage, §40)",
        stimulus:
          "Real CommandBus receipt whose binding links are truncated to the prepared anchor (fields reset to the prepared digests); verify/2",
        boundary: "AshA2A.Receipt.Binding.verify/2 result_bound/2",
        forbidden_outcome: "receipt.binding.verify outcome=verified",
        attempt_evidence:
          "receipt.binding.verify observed AND the persisted receipt's status is not :pending while its binding holds one prepared link",
        survival_evidence: "receipt.binding.verify outcome=verified",
        guard: "Receipt.Binding result_bound/2 (:receipt_binding_result_unbound)",
        failure_class: :receipt_failure,
        rfc_sections: ["§40"],
        attempt_predicate: verify_attempted(),
        outcome_predicate: verified()
      ),
      Falsifier.new!(
        id: "#{@court}-030",
        court_id: @court,
        kind: :positive_control,
        invariant:
          "A prepared anchor verifies before DO and its finalized receipt chains from it (§40, §100)",
        stimulus:
          "Receipt.pending/4 for a :change command; verify/2; Receipt.finalize/2 with {:reply, :ok}; verify/2",
        boundary: "AshA2A.Receipt.pending/4 + finalize/2 + Receipt.Binding.verify/2",
        attempt_evidence: "receipt.binding.bind stage=prepared observed",
        survival_evidence:
          "verify outcome=verified stage=prepared, then verify outcome=verified stage=final, bind before verify; the final link's predecessor is the prepared digest",
        failure_class: :receipt_failure,
        rfc_sections: ["§40", "§100"],
        attempt_predicate: {:observed, "receipt.binding.bind", %{"stage" => "prepared"}},
        outcome_predicate:
          {:all,
           [
             {:observed, "receipt.binding.verify",
              %{"outcome" => "verified", "stage" => "prepared"}},
             {:observed, "receipt.binding.verify",
              %{"outcome" => "verified", "stage" => "final"}},
             {:precedes, "receipt.binding.bind", "receipt.binding.verify"}
           ]}
      )
    ]
  end

  # --- run ------------------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    by_id = Map.new(falsifiers(), &{&1.id, &1})
    f = &Map.fetch!(by_id, "#{@court}-" <> &1)

    Fx.with_key(nil, fn ->
      Fx.with_store(fn store_opts ->
        base = setup(ctx, store_opts)

        tamper_results =
          for {n, field, _} <- @tampers, do: tamper(ctx, f.(n), field, base)

        laundering_results = for {n, _} <- @laundering, do: launder(ctx, f.(n), base)
        standing_results = for {n, _} <- @standing_attacks, do: standing_attack(ctx, f.(n))

        tamper_results ++
          laundering_results ++
          standing_results ++
          [
            standing_clean(ctx, f.("028")),
            reseal(ctx, f.("022"), base),
            downgrade(ctx, f.("023"), store_opts),
            unbacked_keyed(ctx, f.("024"), base),
            reforge(ctx, f.("025"), store_opts),
            intact(ctx, f.("026"), base),
            keyed_intact(ctx, f.("027"), store_opts),
            result_unbound(ctx, f.("029"), base),
            prepared_to_final(ctx, f.("030"))
          ]
      end)
    end)
  end

  # Real receipts produced once, outside any stimulus, and persisted at rest.
  defp setup(ctx, store_opts) do
    honest = Fx.execute("honest", :honest_write, store_opts)
    other = Fx.execute("other", :honest_write, store_opts)
    contradicted = Fx.execute("contradicted", :lying_write, store_opts)

    %{
      dir: ctx.evidence_dir,
      honest: honest.receipt,
      other: other.receipt,
      contradicted: contradicted.receipt,
      honest_path: honest.receipt && Fx.persist!(ctx.evidence_dir, "honest", honest.receipt),
      contradicted_path:
        contradicted.receipt &&
          Fx.persist!(ctx.evidence_dir, "contradicted", contradicted.receipt)
    }
  end

  # --- §40 tamper family ------------------------------------------------------------

  defp tamper(ctx, f, field, base) do
    source = if field == :result_identity, do: base.contradicted_path, else: base.honest_path

    if is_nil(source) do
      Result.unknown(f, "the real CommandBus run produced no stored receipt to tamper")
    else
      original = Fx.read_back!(source)
      tampered = tamper_field(field, original, base)
      path = Fx.persist!(base.dir, f.id, tampered)

      verdict =
        Context.stimulus(ctx, f, fn ->
          path |> Fx.read_back!() |> Binding.verify()
        end)

      on_disk = Fx.read_back!(path)

      negative(ctx, f, [verdict],
        tampered?: projection(field, on_disk) != projection(field, original),
        evidence: %{"field" => Atom.to_string(field), "verdict" => summary(verdict)}
      )
    end
  end

  defp tamper_field(:actor, r, _base),
    do: %{r | actor: Identity.principal("chicago-receipt-mallory")}

  defp tamper_field(:semantic_subject, r, _base),
    do: %{r | semantic_subject: %{r.semantic_subject | graph_digest: Fx.sha("forged-graph")}}

  defp tamper_field(:capability_action, r, _base),
    do: %{r | capability_id: Ledgers.capability(:lying_write)}

  defp tamper_field(:input_digest, r, _base), do: %{r | input_digest: Fx.sha("forged-input")}
  defp tamper_field(:plan_digest, r, _base), do: %{r | plan_digest: Fx.sha("forged-plan")}

  defp tamper_field(:projection_digest, r, _base),
    do: %{r | projection_digest: Fx.sha("forged-projection")}

  defp tamper_field(:authority_grant, r, _base),
    do: %{r | authority_grant: %{r.authority_grant | token_id: "runtime:forged-token"}}

  defp tamper_field(:idempotency_identity, r, _base),
    do: %{r | idempotency_key: Identity.idempotency("forged-idempotency")}

  defp tamper_field(:intended_effect, r, _base),
    do: %{r | intended_effect: %{r.intended_effect | consequence: :observe}}

  defp tamper_field(:result_identity, r, _base) do
    postcondition = r.metadata |> Map.get(:postcondition, %{}) |> Map.put(:status, :verified)

    %{
      r
      | status: :completed,
        terminal_status: :executed,
        metadata: Map.put(r.metadata, :postcondition, postcondition)
    }
  end

  defp tamper_field(:chain_predecessor, r, base) do
    [other_root | _] = base.other.binding.links
    links = List.update_at(r.binding.links, -1, &%{&1 | predecessor: other_root.digest})
    %{r | binding: %{r.binding | links: links}}
  end

  defp tamper_field(:receipt_identity, r, base), do: %{r | receipt_id: base.other.receipt_id}

  defp projection(:capability_action, r), do: {r.capability_id, r.consequence, r.fingerprint}
  defp projection(:idempotency_identity, r), do: {r.actuation_id, r.idempotency_key}

  defp projection(:result_identity, r),
    do: {r.status, r.terminal_status, Map.get(r.metadata || %{}, :postcondition)}

  defp projection(:chain_predecessor, r), do: Enum.map(r.binding.links, & &1.predecessor)
  defp projection(:receipt_identity, r), do: r.receipt_id
  defp projection(field, r), do: Map.fetch!(r, field)

  # --- §128 laundering family --------------------------------------------------------

  defp launder(_ctx, f, %{honest_path: nil}),
    do: Result.unknown(f, "the real CommandBus run produced no stored receipt")

  defp launder(ctx, f, base) do
    original = Fx.read_back!(base.honest_path)

    variants =
      f.id
      |> String.slice(-3, 3)
      |> encodings(original)
      |> Enum.with_index()
      |> Enum.map(fn {{field, variant}, i} ->
        {field, Fx.persist!(base.dir, "#{f.id}-#{i}", variant)}
      end)

    verdicts =
      Context.stimulus(ctx, f, fn ->
        Enum.map(variants, fn {_field, path} -> path |> Fx.read_back!() |> Binding.verify() end)
      end)

    reencoded? =
      Enum.all?(variants, fn {field, path} ->
        Map.fetch!(Fx.read_back!(path), field) != Map.fetch!(original, field)
      end)

    negative(ctx, f, verdicts,
      tampered?: reencoded?,
      evidence: %{"variants" => length(variants), "verdicts" => Enum.map(verdicts, &summary/1)}
    )
  end

  defp encodings("013", r) do
    constraints = Map.put(r.authority_grant.constraints, :scope, "admin")
    [{:authority_grant, %{r | authority_grant: %{r.authority_grant | constraints: constraints}}}]
  end

  defp encodings("014", r) do
    effect = r.intended_effect |> Map.put(:consequence, :observe) |> Enum.sort() |> Keyword.new()
    [{:intended_effect, %{r | intended_effect: effect}}]
  end

  defp encodings("015", r),
    do: [{:authority_grant, %{r | authority_grant: Map.to_list(r.authority_grant)}}]

  defp encodings("016", r) do
    json_grant =
      r.authority_grant
      |> Map.put(:token_id, "runtime:forged-token")
      |> Map.new(fn
        {k, %Identity{} = id} -> {Atom.to_string(k), Identity.external(id)}
        {k, %DateTime{} = dt} -> {Atom.to_string(k), DateTime.to_iso8601(dt)}
        {k, v} when is_atom(v) and not is_nil(v) -> {Atom.to_string(k), Atom.to_string(v)}
        {k, v} -> {Atom.to_string(k), v}
      end)

    [
      {:authority_grant, %{r | authority_grant: json_grant}},
      {:actor, %{r | actor: Identity.external(r.actor)}}
    ]
  end

  defp encodings("017", r) do
    [
      {:intended_effect,
       %{r | intended_effect: Map.put(r.intended_effect, "consequence", :observe)}}
    ]
  end

  # --- §128 standing guard family ------------------------------------------------------

  defp standing_attack(ctx, f) do
    evidence = f.id |> String.slice(-3, 3) |> standing_evidence()
    envelope = envelope(f)

    result =
      Context.stimulus(ctx, f, fn -> Standing.transition(envelope, :received, evidence) end)

    admitted =
      case result do
        {:ok, %Envelope{standing: :received}} -> true
        {:error, _refusal} -> false
        _other -> :unknown
      end

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "semantic.standing.transition", %{"to" => "received"}) and
          contains_llm_output?(evidence),
      forbidden_outcome_observed?:
        either(
          admitted,
          observed?(ctx, f, "semantic.standing.transition", %{"outcome" => "transitioned"})
        ),
      evidence: %{"result" => standing_summary(result)}
    )
  end

  defp standing_clean(ctx, f) do
    evidence =
      transport_evidence()
      |> Map.put(:bundle, source: "bytes", media_type: "text/turtle")
      |> Map.put(:pairs, [{"digest", Fx.sha("clean")}, {:parser, "rdf"}])

    result =
      Context.stimulus(ctx, f, fn -> Standing.transition(envelope(f), :received, evidence) end)

    Result.positive(f,
      attempt_observed?: observed?(ctx, f, "semantic.standing.transition", %{"to" => "received"}),
      expected_outcome_observed?:
        match?({:ok, %Envelope{standing: :received}}, result) and
          observed?(ctx, f, "semantic.standing.transition", %{"outcome" => "transitioned"}),
      evidence: %{"result" => standing_summary(result)}
    )
  end

  defp standing_evidence("018"),
    do: Map.put(transport_evidence(), :bundle, %{llm_output: "a model said so"})

  defp standing_evidence("019"),
    do: Map.put(transport_evidence(), :bundle, llm_output: "a model said so")

  defp standing_evidence("020") do
    transport_evidence()
    |> Map.put(:bundle, [{"llm_output", "a model said so"}])
    |> Map.put(:tagged, {:llm_output, "a model said so"})
  end

  defp standing_evidence("021") do
    transport_evidence()
    |> Map.put("llmOutput", "a model said so")
    |> Map.put(:bundle, %{"LLM-Output" => "a model said so"})
  end

  defp transport_evidence, do: %{transport: "https", received_at: "2026-09-16T00:00:00Z"}

  defp envelope(f) do
    Envelope.new!(%{
      envelope_id: "urn:chicago:#{f.id}:#{System.unique_integer([:positive])}",
      kind: "sa2a:Request"
    })
  end

  # The court's own reader: a name-normalizing walk independent of the guard.
  defp contains_llm_output?(term) do
    case term do
      %_{} ->
        term |> Map.from_struct() |> contains_llm_output?()

      %{} ->
        Enum.any?(term, fn {k, v} -> llm_name?(k) or contains_llm_output?(v) end)

      {k, v} ->
        llm_name?(k) or contains_llm_output?(v)

      list when is_list(list) ->
        Enum.any?(list, &contains_llm_output?/1)

      tuple when is_tuple(tuple) ->
        tuple |> Tuple.to_list() |> contains_llm_output?()

      _ ->
        false
    end
  end

  defp llm_name?(name) when is_atom(name) or is_binary(name),
    do:
      name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "") == "llmoutput"

  defp llm_name?(_name), do: false

  # --- chain & key posture --------------------------------------------------------------

  defp reseal(_ctx, f, %{honest_path: nil}), do: Result.unknown(f, "no stored receipt")

  defp reseal(ctx, f, base) do
    tampered = tamper_field(:actor, Fx.read_back!(base.honest_path), base)
    path = Fx.persist!(base.dir, f.id, tampered)

    {reconciled, verdict} =
      Context.stimulus(ctx, f, fn ->
        reconciled = path |> Fx.read_back!() |> Receipt.reconcile(%{source: :chicago_court})
        {reconciled, Binding.verify(reconciled)}
      end)

    negative(ctx, f, [verdict],
      tampered?: reconciled.actor == Identity.principal("chicago-receipt-mallory"),
      extra_attempt: observed?(ctx, f, "receipt.binding.bind", %{"stage" => "reconciled"}),
      extra_forbidden:
        observed?(ctx, f, "receipt.binding.bind", %{"stage" => "reconciled", "outcome" => "bound"}),
      evidence: %{"verdict" => summary(verdict)}
    )
  end

  defp downgrade(ctx, f, store_opts) do
    Fx.with_key(@key, fn ->
      case Fx.execute("downgrade", :honest_write, store_opts) do
        %{receipt: %Receipt{binding: %{keyed: true}} = keyed} ->
          forged = reforge(tamper_field(:actor, keyed, nil), nil)
          path = Fx.persist!(ctx.evidence_dir, f.id, forged)

          verdict =
            Context.stimulus(ctx, f, fn -> path |> Fx.read_back!() |> Binding.verify() end)

          negative(ctx, f, [verdict],
            tampered?: match?({:ok, %{keyed: false}}, Binding.check(forged, key: nil)),
            evidence: %{"verdict" => summary(verdict)}
          )

        other ->
          Result.unknown(f, "keyed run produced no keyed receipt: #{inspect(other, limit: 5)}")
      end
    end)
  end

  defp unbacked_keyed(_ctx, f, %{honest_path: nil}), do: Result.unknown(f, "no stored receipt")

  defp unbacked_keyed(ctx, f, base) do
    original = Fx.read_back!(base.honest_path)

    claimed =
      %{
        original
        | binding: %{
            original.binding
            | keyed: true,
              algorithm: "hmac-sha256",
              key_id: Binding.key_id(@key)
          }
      }

    path = Fx.persist!(base.dir, f.id, claimed)

    verdicts =
      Context.stimulus(ctx, f, fn ->
        [
          path |> Fx.read_back!() |> Binding.verify(),
          Fx.with_key(@key, fn -> path |> Fx.read_back!() |> Binding.verify() end)
        ]
      end)

    negative(ctx, f, verdicts,
      tampered?: original.binding.keyed == false and Fx.read_back!(path).binding.keyed == true,
      forbidden_when: &match?({:ok, %{keyed: true}}, &1),
      evidence: %{"verdicts" => Enum.map(verdicts, &summary/1)}
    )
  end

  defp reforge(ctx, f, store_opts) do
    Fx.with_key(@key, fn ->
      case Fx.execute("reforge", :honest_write, store_opts) do
        %{receipt: %Receipt{binding: %{keyed: true}} = keyed} ->
          tampered = tamper_field(:actor, keyed, nil)
          as_is = reforge(tampered, @attacker_key)
          relabelled = %{as_is | binding: %{as_is.binding | key_id: Binding.key_id(@key)}}

          paths = [
            Fx.persist!(ctx.evidence_dir, f.id <> "-a", as_is),
            Fx.persist!(ctx.evidence_dir, f.id <> "-b", relabelled)
          ]

          verdicts =
            Context.stimulus(ctx, f, fn ->
              Enum.map(paths, &(&1 |> Fx.read_back!() |> Binding.verify()))
            end)

          negative(ctx, f, verdicts,
            tampered?: match?({:ok, _}, Binding.check(as_is, key: @attacker_key)),
            evidence: %{"verdicts" => Enum.map(verdicts, &summary/1)}
          )

        other ->
          Result.unknown(f, "keyed run produced no keyed receipt: #{inspect(other, limit: 5)}")
      end
    end)
  end

  # A complete, internally consistent chain over `receipt`'s current content
  # built only from public API: what a writer holding `key` (or no key) can do.
  defp reforge(%Receipt{} = receipt, key) do
    %{receipt | status: :pending, binding: nil}
    |> Binding.bind(key: key)
    |> Binding.transition(receipt, :final, key: key)
  end

  defp intact(_ctx, f, %{honest_path: nil}), do: Result.unknown(f, "no stored receipt")

  defp intact(ctx, f, base) do
    verdicts =
      Context.stimulus(ctx, f, fn ->
        [Binding.verify(base.honest), base.honest_path |> Fx.read_back!() |> Binding.verify()]
      end)

    links = base.honest.binding.links

    chained? =
      match?([%{stage: :prepared} | _], links) and
        links
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.all?(fn [a, b] -> b.predecessor == a.digest end)

    Result.positive(f,
      attempt_observed?: observed?(ctx, f, "receipt.binding.verify", %{}),
      expected_outcome_observed?:
        Enum.all?(verdicts, &match?({:ok, %{keyed: false, stage: :postcondition}}, &1)) and
          chained? and
          observed?(ctx, f, "receipt.binding.verify", %{
            "outcome" => "verified",
            "keyed" => "false"
          }),
      evidence: %{"verdicts" => Enum.map(verdicts, &summary/1), "links" => length(links)}
    )
  end

  defp keyed_intact(ctx, f, store_opts) do
    Fx.with_key(@key, fn ->
      case Fx.execute("keyed", :honest_write, store_opts) do
        %{receipt: %Receipt{} = receipt} ->
          path = Fx.persist!(ctx.evidence_dir, f.id, receipt)

          {first, second} =
            Context.stimulus(ctx, f, fn ->
              read = Fx.read_back!(path)
              first = Binding.verify(read)
              reconciled = Receipt.reconcile(read, %{source: :chicago_court})
              {first, Binding.verify(reconciled)}
            end)

          Result.positive(f,
            attempt_observed?:
              observed?(ctx, f, "receipt.binding.verify", %{"key_configured" => "true"}),
            expected_outcome_observed?:
              match?({:ok, %{keyed: true}}, first) and
                match?({:ok, %{keyed: true, stage: :reconciled}}, second),
            evidence: %{"first" => summary(first), "second" => summary(second)}
          )

        other ->
          Result.unknown(f, "keyed run produced no receipt: #{inspect(other, limit: 5)}")
      end
    end)
  end

  defp result_unbound(_ctx, f, %{honest_path: nil}), do: Result.unknown(f, "no stored receipt")

  defp result_unbound(ctx, f, base) do
    original = Fx.read_back!(base.honest_path)
    [root | _] = original.binding.links

    truncated = %{
      original
      | binding: %{
          original.binding
          | links: [root],
            fields: Binding.field_digests(original, :prepared)
        }
    }

    path = Fx.persist!(base.dir, f.id, truncated)
    verdict = Context.stimulus(ctx, f, fn -> path |> Fx.read_back!() |> Binding.verify() end)
    on_disk = Fx.read_back!(path)

    negative(ctx, f, [verdict],
      tampered?: on_disk.status != :pending and length(on_disk.binding.links) == 1,
      evidence: %{"verdict" => summary(verdict), "status" => Atom.to_string(on_disk.status)}
    )
  end

  defp prepared_to_final(ctx, f) do
    command =
      Command.new(Ledgers.capability(:honest_write),
        command_id: "chicago-receipt-anchor-#{System.unique_integer([:positive])}",
        agent_id: "chicago-receipt-agent",
        principal_id: Identity.principal("chicago-receipt-subject"),
        input: %{key: "anchor", value: "X"}
      )

    {anchor, prepared, final, finalized} =
      Context.stimulus(ctx, f, fn ->
        anchor = Receipt.pending(command, Identity.execution("chicago-receipt-exec"), :change)
        prepared = Binding.verify(anchor)
        finalized = Receipt.finalize(anchor, {:reply, :ok})
        {anchor, prepared, Binding.verify(finalized), finalized}
      end)

    [%{digest: root_digest}] = anchor.binding.links

    Result.positive(f,
      attempt_observed?: observed?(ctx, f, "receipt.binding.bind", %{"stage" => "prepared"}),
      expected_outcome_observed?:
        match?({:ok, %{stage: :prepared}}, prepared) and match?({:ok, %{stage: :final}}, final) and
          match?(
            [%{digest: ^root_digest}, %{predecessor: ^root_digest}],
            finalized.binding.links
          ),
      evidence: %{"prepared" => summary(prepared), "final" => summary(final)}
    )
  end

  # --- verdict helpers -------------------------------------------------------------------

  # PASS = attempt observed (boundary event + tamper really on disk) ∧ no verdict verified.
  defp negative(ctx, f, verdicts, opts) do
    forbidden_when = Keyword.get(opts, :forbidden_when, &match?({:ok, _}, &1))

    forbidden =
      Enum.any?(verdicts, forbidden_when) or
        observed?(ctx, f, "receipt.binding.verify", forbidden_attrs(f)) or
        Keyword.get(opts, :extra_forbidden, false)

    Result.negative(f,
      attempt_observed?:
        observed?(ctx, f, "receipt.binding.verify", %{}) and Keyword.fetch!(opts, :tampered?) and
          Keyword.get(opts, :extra_attempt, true),
      forbidden_outcome_observed?: forbidden,
      evidence: Keyword.get(opts, :evidence, %{})
    )
  end

  defp forbidden_attrs(%Falsifier{id: "CHI-RECEIPT-024"}),
    do: %{"outcome" => "verified", "keyed" => "true"}

  defp forbidden_attrs(_f), do: %{"outcome" => "verified"}

  defp either(true, _), do: true
  defp either(_, true), do: true
  defp either(:unknown, _), do: :unknown
  defp either(_, _), do: false

  defp observed?(ctx, f, activity, attrs) do
    ctx
    |> Context.observed(f)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} -> to_string(Map.get(record.attributes, k)) == v end)
    end)
  end

  defp summary({:ok, report}),
    do: "verified:#{report.stage}:keyed=#{report.keyed}"

  defp summary({:error, %{code: code} = refusal}),
    do: "refused:#{code}#{fields_suffix(refusal)}"

  defp summary(other), do: inspect(other, limit: 5)

  defp fields_suffix(%{detail: %{fields: fields}}),
    do: ":" <> Enum.map_join(fields, ",", &Atom.to_string/1)

  defp fields_suffix(_refusal), do: ""

  defp standing_summary({:ok, %Envelope{standing: standing}}), do: "transitioned:#{standing}"
  defp standing_summary({:error, %{code: code}}), do: "refused:#{code}"
  defp standing_summary(other), do: inspect(other, limit: 5)
end
