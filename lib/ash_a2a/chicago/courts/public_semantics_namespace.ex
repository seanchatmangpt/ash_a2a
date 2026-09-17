defmodule AshA2A.Chicago.Courts.PublicSemanticsNamespace do
  @moduledoc """
  RFC-SA2A-002 §51 Public-Semantics and Namespace court (RFC-SA2A-001 S7.1-S7.3,
  S47).

    * Public IRIs are reused where they exist: `AshA2A.Semantic.Iri.resolve/2`
      over the real digest-pinned W3C term index
      (`AshA2A.Semantic.TermRegistry.from_cache/1`) reuses `skos:Concept`, and
      refuses to mint a private IRI while a public term is available.
    * Private terms carry provenance, scope, version and an admission receipt:
      the real `Iri.mint_private/1` refuses each missing obligation.
    * Strict refuses runtime invention of operational private vocabulary:
      `TermRegistry.admit_operational_use/3` refuses the IRI
      `AshA2A.Semantic.Vocabulary.expand/1` mints at runtime for an unknown
      prefix, and an invented term spelled under an admitted namespace.
    * Label / textual similarity never implies semantic equality: identical
      labels over different identities are refused by
      `AshA2A.Semantic.MappingRegistry.reconcile/3`, and a public term found
      only by textual containment is not adopted as the concept's identity
      without an explicitly admitted mapping.
    * Explicit mappings are admitted before cross-identity composition: an
      unadmitted mapping neither registers nor reconciles, and composing public
      models (S7.2 step 4) requires admitted mappings.

  Attempt evidence: `[:ash_a2a, :semantic, :iri, :resolve | :mint_private]`,
  `[:ash_a2a, :semantic, :term_registry, :operational_use]`,
  `[:ash_a2a, :semantic, :mapping_registry, :register | :reconcile]`.
  """

  use AshA2A.Chicago.Court

  alias AshA2A.Chicago.{Context, Falsifier, Result}
  alias AshA2A.Chicago.Fixtures.CanonicalIdentity, as: F
  alias AshA2A.Semantic.{Iri, MappingRegistry, TermRegistry, Vocabulary}

  @court "SA2A-NS"

  @impl true
  def id, do: @court
  @impl true
  def title, do: "Public semantics reuse, private-term obligations, no label-implied identity"
  @impl true
  def gate, do: nil
  @impl true
  def profile, do: :core
  @impl true
  def rfc_sections, do: ["§51", "§100", "RFC-SA2A-001 S7", "S47"]

  @impl true
  def ocel_mappings, do: F.mappings()

  # --- declarations -----------------------------------------------------------

  @resolve {:observed, "iri.resolve"}
  @mint {:observed, "iri.mint_private"}
  @use {:observed, "term_registry.operational_use"}
  @reconcile {:observed, "mapping_registry.reconcile"}

  defp resolved(outcome), do: {:observed, "iri.resolve", %{"outcome" => outcome}}

  @impl true
  def falsifiers do
    [
      declare(1, :positive_control,
        invariant: "A concept with an exact public term reuses the public IRI (S7.2 steps 1-2)",
        stimulus: "Iri.resolve(\"Concept\", index: <pinned W3C index>)",
        boundary: "AshA2A.Semantic.Iri.resolve/2",
        attempt_evidence: "iri.resolve observed",
        survival_evidence: "iri.resolve outcome=reused_public_iri with iri skos:Concept",
        attempt_predicate: @resolve,
        outcome_predicate: resolved("reused_public_iri")
      ),
      declare(2, :negative,
        invariant: "A private IRI is not minted while an exact public term is available",
        stimulus:
          "Iri.resolve(\"Concept\", sufficient?: false, accept_equivalent?: false, private_term: <complete>) with no written insufficiency reason",
        boundary: "AshA2A.Semantic.Iri.resolve/2 step 5",
        forbidden_outcome: "minted_private_iri",
        attempt_evidence: "iri.resolve observed",
        survival_evidence: "iri.resolve outcome=minted_private_iri",
        guard: "Iri.mint_step/4 :private_mint_refused_public_available",
        failure_class: :identity_failure,
        attempt_predicate: @resolve,
        outcome_predicate: resolved("minted_private_iri")
      ),
      declare(3, :negative,
        invariant:
          "Textual similarity does not confer identity: a public term found only by label containment is not adopted without an admitted mapping",
        stimulus:
          "Iri.resolve(\"Concept\", sufficient?: false) -- step 3 finds skos:ConceptScheme, skos:hasTopConcept, skos:topConceptOf by substring",
        boundary: "AshA2A.Semantic.Iri.resolve/2 step 3",
        forbidden_outcome: "reused_equivalent_public_iri chosen by textual similarity",
        attempt_evidence: "iri.resolve observed",
        survival_evidence: "iri.resolve outcome=reused_equivalent_public_iri",
        guard: "Iri step 3 admitted-mapping requirement",
        failure_class: :identity_failure,
        attempt_predicate: @resolve,
        outcome_predicate: resolved("reused_equivalent_public_iri")
      ),
      declare(4, :positive_control,
        invariant:
          "Positive control for 003: an explicitly admitted mapping to one equivalent public term is honoured",
        stimulus:
          "Iri.resolve(\"Concept\", sufficient?: false, mappings: [<admitted mapping to the LAST textual equivalent>])",
        boundary: "AshA2A.Semantic.Iri.resolve/2 step 3",
        attempt_evidence: "iri.resolve observed",
        survival_evidence:
          "iri.resolve outcome=reused_equivalent_public_iri; iri == the mapped target",
        attempt_predicate: @resolve,
        outcome_predicate: resolved("reused_equivalent_public_iri")
      ),
      declare(5, :negative,
        invariant:
          "Cross-identity composition of public models requires admitted mappings (receipts), not bare assertions",
        stimulus:
          "Iri.resolve(\"Concept\", composition: [skos:Concept, owl:Class], mappings: <kinds and targets, no admission receipts>)",
        boundary: "AshA2A.Semantic.Iri.resolve/2 step 4",
        forbidden_outcome: "composed_public_models",
        attempt_evidence: "iri.resolve observed",
        survival_evidence: "iri.resolve outcome=composed_public_models",
        guard: "Iri.mappings_cover/2 admission-receipt requirement",
        failure_class: :identity_failure,
        attempt_predicate: @resolve,
        outcome_predicate: resolved("composed_public_models")
      ),
      declare(6, :positive_control,
        invariant: "Positive control for 005: composition with admitted mappings is composed",
        stimulus: "Iri.resolve/2 step 4 with admitted mappings for both composed models",
        boundary: "AshA2A.Semantic.Iri.resolve/2 step 4",
        attempt_evidence: "iri.resolve observed",
        survival_evidence: "iri.resolve outcome=composed_public_models",
        attempt_predicate: @resolve,
        outcome_predicate: resolved("composed_public_models")
      )
    ] ++
      Enum.map(mint_attacks(), fn {n, _override, what, guard} ->
        declare(n, :negative,
          invariant: "A private term is not mintable #{what}",
          stimulus: "Iri.mint_private/1 of a complete private term #{what}",
          boundary: "AshA2A.Semantic.Iri.mint_private/1",
          forbidden_outcome: "minted",
          attempt_evidence: "iri.mint_private observed",
          survival_evidence: "iri.mint_private outcome=minted",
          guard: guard,
          failure_class: :identity_failure,
          attempt_predicate: @mint,
          outcome_predicate: {:observed, "iri.mint_private", %{"outcome" => "minted"}}
        )
      end) ++
      [
        declare(11, :positive_control,
          invariant:
            "Positive control for 007-010: a private term with provenance, scope, pinned version and receipt mints",
          stimulus: "Iri.mint_private/1 of the complete private term",
          boundary: "AshA2A.Semantic.Iri.mint_private/1",
          attempt_evidence: "iri.mint_private observed",
          survival_evidence: "iri.mint_private outcome=minted",
          attempt_predicate: @mint,
          outcome_predicate: {:observed, "iri.mint_private", %{"outcome" => "minted"}}
        ),
        use_negative(12,
          invariant:
            "Strict refuses runtime-minted private vocabulary as operational semantics (Vocabulary.expand/1's URN)",
          stimulus:
            "TermRegistry.admit_operational_use/3 (strict, consequential) of Vocabulary.expand(\"acme:widget\")"
        ),
        use_negative(13,
          invariant:
            "Strict refuses an invented term spelled under an admitted public namespace (prefix is not membership)",
          stimulus:
            "TermRegistry.admit_operational_use/3 (strict, consequential) of skos:chicagoInventedTerm"
        ),
        declare(14, :positive_control,
          invariant:
            "Positive control for 012-013: an admitted public term is operational under Strict",
          stimulus:
            "TermRegistry.admit_operational_use/3 (strict, consequential) of skos:prefLabel",
          boundary: "AshA2A.Semantic.TermRegistry.admit_operational_use/3",
          attempt_evidence: "term_registry.operational_use observed",
          survival_evidence: "term_registry.operational_use outcome=admitted",
          attempt_predicate: @use,
          outcome_predicate:
            {:observed, "term_registry.operational_use", %{"outcome" => "admitted"}}
        ),
        declare(15, :negative,
          invariant:
            "label_A == label_B does not imply meaning_A == meaning_B: equal labels over different identities do not reconcile",
          stimulus:
            "MappingRegistry.reconcile/3 of peers labelled \"Create Invoice\"/\"create invoice\" with different IRIs and no mapping",
          boundary: "AshA2A.Semantic.MappingRegistry.reconcile/3",
          forbidden_outcome: "same_semantic_identity or admitted_mapping",
          attempt_evidence: "mapping_registry.reconcile observed",
          survival_evidence: "mapping_registry.reconcile outcome other than refused",
          guard: "MappingRegistry.reconcile/3 identity-then-admitted-mapping order",
          failure_class: :identity_failure,
          attempt_predicate: @reconcile,
          outcome_predicate:
            {:not_observed, "mapping_registry.reconcile", %{"outcome" => "refused"}}
        ),
        declare(16, :negative,
          invariant:
            "A mapping asserted without an admission receipt neither registers nor enables cross-identity reconciliation",
          stimulus:
            "MappingRegistry.register/2 of an exact_match between the two identities with no receipt, then reconcile/3",
          boundary: "AshA2A.Semantic.MappingRegistry.register/2 + reconcile/3",
          forbidden_outcome: "registered, or reconcile outcome admitted_mapping",
          attempt_evidence: "mapping_registry.reconcile observed",
          survival_evidence:
            "mapping_registry.register outcome=registered or mapping_registry.reconcile outcome=admitted_mapping",
          guard: "MappingRegistry.check_receipt/1",
          failure_class: :identity_failure,
          attempt_predicate: {:all, [{:observed, "mapping_registry.register"}, @reconcile]},
          outcome_predicate:
            {:any,
             [
               {:observed, "mapping_registry.register", %{"outcome" => "registered"}},
               {:observed, "mapping_registry.reconcile", %{"outcome" => "admitted_mapping"}}
             ]}
        ),
        declare(17, :positive_control,
          invariant: "Positive control for 015-016: an admitted mapping reconciles the same pair",
          stimulus: "MappingRegistry.register/2 with an admission receipt, then reconcile/3",
          boundary: "AshA2A.Semantic.MappingRegistry.register/2 + reconcile/3",
          attempt_evidence: "mapping_registry.reconcile observed",
          survival_evidence: "register registered and reconcile outcome=admitted_mapping",
          attempt_predicate: @reconcile,
          outcome_predicate:
            {:all,
             [
               {:observed, "mapping_registry.register", %{"outcome" => "registered"}},
               {:observed, "mapping_registry.reconcile", %{"outcome" => "admitted_mapping"}}
             ]}
        ),
        declare(18, :positive_control,
          invariant:
            "Positive control for 015: identity, not label, decides -- different labels over one IRI reconcile",
          stimulus: "MappingRegistry.reconcile/3 of peers with different labels and the same IRI",
          boundary: "AshA2A.Semantic.MappingRegistry.reconcile/3",
          attempt_evidence: "mapping_registry.reconcile observed",
          survival_evidence: "mapping_registry.reconcile outcome=same_semantic_identity",
          attempt_predicate: @reconcile,
          outcome_predicate:
            {:observed, "mapping_registry.reconcile", %{"outcome" => "same_semantic_identity"}}
        )
      ]
  end

  defp mint_attacks do
    [
      {7, %{provenance: %{searched_sources: [], public_absence_reason: ""}},
       "without a recorded public search (provenance)", "Iri.check_provenance/1"},
      {8, %{version: "latest"}, "with a moving version pointer", "Iri.check_version/1"},
      {9, %{scope: :public}, "with a public scope", "Iri.check_private_scope/1"},
      {10, %{admission_receipt: %{receipt_id: "", fingerprint: ""}},
       "without an admission receipt", "Iri.check_receipt/1"}
    ]
  end

  defp use_negative(n, fields) do
    declare(
      n,
      :negative,
      [
        boundary: "AshA2A.Semantic.TermRegistry.admit_operational_use/3 (Strict)",
        forbidden_outcome: "admitted as operational semantics",
        attempt_evidence: "term_registry.operational_use observed",
        survival_evidence: "term_registry.operational_use outcome=admitted",
        guard: "TermRegistry.admit_operational_use/3 index-membership check",
        failure_class: :identity_failure,
        attempt_predicate: @use,
        outcome_predicate:
          {:observed, "term_registry.operational_use", %{"outcome" => "admitted"}}
      ] ++ fields
    )
  end

  defp fid(n), do: "#{@court}-" <> String.pad_leading(Integer.to_string(n), 3, "0")

  defp declare(n, kind, fields) do
    Falsifier.new!([id: fid(n), court_id: @court, kind: kind, rfc_sections: ["§51"]] ++ fields)
  end

  # --- execution --------------------------------------------------------------

  @impl true
  def run(%Context{} = ctx) do
    fs = Map.new(falsifiers(), &{&1.id, &1})
    f = fn n -> Map.fetch!(fs, fid(n)) end

    case TermRegistry.from_cache() do
      {:ok, index} ->
        resolution(ctx, f, index) ++
          minting(ctx, f) ++ operational(ctx, f, index) ++ reconciliation(ctx, f)

      {:error, reason} ->
        for falsifier <- falsifiers(),
            do: Result.blocked(falsifier, "pinned W3C term index unavailable: #{inspect(reason)}")
    end
  end

  defp resolution(ctx, f, index) do
    concept = F.skos_concept()
    owl_class = F.owl_class()
    equivalents = TermRegistry.search_equivalent(index, "Concept")
    mapped = List.last(equivalents)

    r1 = Context.stimulus(ctx, f.(1), fn -> Iri.resolve("Concept", index: index) end)

    r2 =
      Context.stimulus(ctx, f.(2), fn ->
        Iri.resolve("Concept",
          index: index,
          sufficient?: false,
          accept_equivalent?: false,
          private_term: F.private_term()
        )
      end)

    r3 =
      Context.stimulus(ctx, f.(3), fn ->
        Iri.resolve("Concept", index: index, sufficient?: false)
      end)

    r4 =
      Context.stimulus(ctx, f.(4), fn ->
        Iri.resolve("Concept",
          index: index,
          sufficient?: false,
          mappings: [
            %{target: mapped, kind: :close_match, admission_receipt: F.receipt("equivalent")}
          ]
        )
      end)

    composition = [concept, owl_class]

    r5 =
      Context.stimulus(ctx, f.(5), fn ->
        Iri.resolve("Concept",
          index: index,
          sufficient?: false,
          accept_equivalent?: false,
          composition: composition,
          mappings: [
            %{target: concept, kind: :exact_match},
            %{target: owl_class, kind: :close_match}
          ]
        )
      end)

    r6 =
      Context.stimulus(ctx, f.(6), fn ->
        Iri.resolve("Concept",
          index: index,
          sufficient?: false,
          accept_equivalent?: false,
          composition: composition,
          mappings: [
            %{target: concept, kind: :exact_match, admission_receipt: F.receipt("compose-1")},
            %{target: owl_class, kind: :close_match, admission_receipt: F.receipt("compose-2")}
          ]
        )
      end)

    [
      positive(
        ctx,
        f.(1),
        "iri.resolve",
        r1,
        match?({:ok, %{outcome: :reused_public_iri, iri: ^concept}}, r1)
      ),
      negative(ctx, f.(2), "iri.resolve", r2, match?({:ok, %{outcome: :minted_private_iri}}, r2)),
      negative(
        ctx,
        f.(3),
        "iri.resolve",
        r3,
        match?({:ok, %{outcome: :reused_equivalent_public_iri}}, r3),
        %{"textual_equivalents" => equivalents}
      ),
      positive(
        ctx,
        f.(4),
        "iri.resolve",
        r4,
        is_binary(mapped) and
          match?({:ok, %{outcome: :reused_equivalent_public_iri, iri: ^mapped}}, r4),
        %{"mapped_target" => mapped}
      ),
      negative(
        ctx,
        f.(5),
        "iri.resolve",
        r5,
        match?({:ok, %{outcome: :composed_public_models}}, r5)
      ),
      positive(
        ctx,
        f.(6),
        "iri.resolve",
        r6,
        match?({:ok, %{outcome: :composed_public_models, iris: ^composition}}, r6)
      )
    ]
  end

  defp minting(ctx, f) do
    attacks =
      Enum.map(mint_attacks(), fn {n, override, _what, _guard} ->
        reply = Context.stimulus(ctx, f.(n), fn -> Iri.mint_private(F.private_term(override)) end)
        negative(ctx, f.(n), "iri.mint_private", reply, match?({:ok, _}, reply))
      end)

    reply = Context.stimulus(ctx, f.(11), fn -> Iri.mint_private(F.private_term()) end)
    attacks ++ [positive(ctx, f.(11), "iri.mint_private", reply, match?({:ok, _}, reply))]
  end

  defp operational(ctx, f, index) do
    strict = [profile: :strict, consequential?: true]
    minted = Vocabulary.expand("acme:widget")
    invented = F.skos_ns() <> "chicagoInventedTerm"
    pref_label = F.skos_ns() <> "prefLabel"

    r12 =
      Context.stimulus(ctx, f.(12), fn ->
        TermRegistry.admit_operational_use(index, minted, strict)
      end)

    r13 =
      Context.stimulus(ctx, f.(13), fn ->
        TermRegistry.admit_operational_use(index, invented, strict)
      end)

    r14 =
      Context.stimulus(ctx, f.(14), fn ->
        TermRegistry.admit_operational_use(index, pref_label, strict)
      end)

    [
      negative(
        ctx,
        f.(12),
        "term_registry.operational_use",
        r12,
        match?({:ok, {:admitted, _}}, r12),
        %{"iri" => minted}
      ),
      negative(
        ctx,
        f.(13),
        "term_registry.operational_use",
        r13,
        match?({:ok, {:admitted, _}}, r13),
        %{"iri" => invented}
      ),
      positive(
        ctx,
        f.(14),
        "term_registry.operational_use",
        r14,
        r14 == {:ok, {:admitted, pref_label}}
      )
    ]
  end

  defp reconciliation(ctx, f) do
    {a, b} = F.peers(:same_label_different_identity)
    mapping = %{source: a.iri, target: b.iri, kind: :exact_match}

    r15 =
      Context.stimulus(ctx, f.(15), fn ->
        MappingRegistry.reconcile(MappingRegistry.new(), a, b)
      end)

    {registered16, r16} =
      Context.stimulus(ctx, f.(16), fn ->
        registered = MappingRegistry.register(MappingRegistry.new(), mapping)

        registry =
          case registered do
            {:ok, registry} -> registry
            {:error, _} -> MappingRegistry.new()
          end

        {registered, MappingRegistry.reconcile(registry, a, b)}
      end)

    {registered17, r17} =
      Context.stimulus(ctx, f.(17), fn ->
        F.with_store(fn store ->
          admitted =
            Map.put(mapping, :admission_receipt, F.held_mapping_receipt(store, a.iri, b.iri))

          registry = MappingRegistry.new(receipt_store: {AshA2A.ReceiptStore.Memory, name: store})

          case MappingRegistry.register(registry, admitted) do
            {:ok, registry} -> {:registered, MappingRegistry.reconcile(registry, a, b)}
            {:error, _} = refused -> {refused, refused}
          end
        end)
      end)

    {same_a, same_b} = F.peers(:same_identity)

    r18 =
      Context.stimulus(ctx, f.(18), fn ->
        MappingRegistry.reconcile(MappingRegistry.new(), same_a, same_b)
      end)

    [
      negative(ctx, f.(15), "mapping_registry.reconcile", r15, match?({:ok, _}, r15)),
      Result.negative(f.(16),
        attempt_observed?:
          F.observed?(ctx, f.(16), "mapping_registry.register") and
            F.observed?(ctx, f.(16), "mapping_registry.reconcile"),
        forbidden_outcome_observed?:
          match?({:ok, _}, registered16) or match?({:ok, %{outcome: :admitted_mapping}}, r16),
        evidence: %{"register" => summarize(registered16), "reconcile" => summarize(r16)}
      ),
      positive(
        ctx,
        f.(17),
        "mapping_registry.reconcile",
        r17,
        registered17 == :registered and match?({:ok, %{outcome: :admitted_mapping}}, r17)
      ),
      positive(
        ctx,
        f.(18),
        "mapping_registry.reconcile",
        r18,
        match?({:ok, %{outcome: :same_semantic_identity}}, r18)
      )
    ]
  end

  defp negative(ctx, falsifier, activity, reply, forbidden, evidence \\ %{}) do
    Result.negative(falsifier,
      attempt_observed?: F.observed?(ctx, falsifier, activity),
      forbidden_outcome_observed?: forbidden,
      evidence: Map.put(evidence, "reply", summarize(reply))
    )
  end

  defp positive(ctx, falsifier, activity, reply, expected, evidence \\ %{}) do
    Result.positive(falsifier,
      attempt_observed?: F.observed?(ctx, falsifier, activity),
      expected_outcome_observed?: expected,
      evidence: Map.put(evidence, "reply", summarize(reply))
    )
  end

  defp summarize({:ok, %Iri.Resolution{} = r}),
    do: %{"outcome" => r.outcome, "step" => r.step, "iri" => r.iri, "iris" => r.iris}

  defp summarize({:ok, %Iri.PrivateTerm{iri: iri}}), do: %{"minted" => iri}
  defp summarize({:ok, %MappingRegistry{}}), do: %{"outcome" => "registered"}
  defp summarize({:ok, %{outcome: outcome}}), do: %{"outcome" => outcome}
  defp summarize({:ok, other}), do: %{"ok" => inspect(other)}
  defp summarize({:error, %{code: code}}), do: %{"refused" => code}
  defp summarize(other), do: %{"reply" => inspect(other)}
end
