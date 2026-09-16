defmodule AshA2A.Semantic.FalsifierFixtures do
  @moduledoc """
  The RFC S61 conformance fixtures: one positive and one negative graph for
  each of the fourteen mandatory falsifiers.

  A falsifier with only a positive fixture has not been shown to
  *discriminate* -- it has only been shown to fire. Every falsifier here
  therefore ships both, and the pair differs **only** in the condition under
  test, so the negative fixture is a real control and not merely a different
  graph.

  These fixtures are stronger than pairwise: each positive fixture is built
  to trip **exactly one** falsifier, so

      run(positive(id)).tripped == [id]
      run(negative(id)).tripped == []

  holds for all fourteen. That is asserted directly in
  `test/ash_a2a/semantic/falsifier_suite_test.exs`, and it establishes
  cross-falsifier discrimination (a fixture for F09 does not also trip F10)
  in addition to positive/negative discrimination.

  Getting that isolation right is why, for example, the F09
  (`artifact_lacking_provenance`) positive fixture *does* carry a
  `sa:canonicalDigest`: without it the fixture would also trip F10
  (`artifact_lacking_canonical_identity`) and the two falsifiers would be
  indistinguishable on it.

  Fixtures live in `lib/` rather than `test/support/` deliberately: they are
  the shipped conformance suite of RFC S61, not test scaffolding, and a
  conformance suite that only exists inside the test build cannot be run
  against another runtime.
  """

  alias AshA2A.Semantic.FalsifierSuite, as: Suite

  @ex "http://example.org/sa2a-fixture#"

  defp ex(local), do: @ex <> local
  defp sa(local), do: Suite.sa(local)
  defp prov(local), do: Suite.prov(local)
  defp a, do: Suite.rdf_type()

  @doc "The fixture namespace IRI."
  def namespace, do: @ex

  @doc """
  The positive fixture for `id`: a graph in which the falsifier's violating
  condition IS present, so the falsifier trips.
  """
  @spec positive(atom()) :: {:ok, [tuple()]} | {:error, map()}
  def positive(id) do
    if id in Suite.ids() do
      {:ok, pos(id)}
    else
      {:error, %{code: :unknown_falsifier, detail: id}}
    end
  end

  @doc """
  The negative fixture for `id`: the same shape with the violating condition
  repaired, so the falsifier does NOT trip. This is the control that shows
  the falsifier discriminates rather than merely firing.
  """
  @spec negative(atom()) :: {:ok, [tuple()]} | {:error, map()}
  def negative(id) do
    if id in Suite.ids() do
      {:ok, neg(id)}
    else
      {:error, %{code: :unknown_falsifier, detail: id}}
    end
  end

  @doc "Every fixture as `{id, positive_graph, negative_graph}`, in RFC order."
  @spec all() :: [{atom(), [tuple()], [tuple()]}]
  def all do
    Enum.map(Suite.ids(), fn id -> {id, pos(id), neg(id)} end)
  end

  # ==========================================================================
  # Positive fixtures: the violating condition IS present (falsifier trips).
  # ==========================================================================

  # -- S61.1  consequence without authority requirement --
  defp pos(:consequence_without_authority_requirement) do
    [{ex("cmd1"), sa("hasConsequence"), ex("writeLedger")}]
  end

  # -- S61.2  DO without prepared-receipt requirement --
  defp pos(:do_without_prepared_receipt) do
    [{ex("do1"), a(), sa("DoStep")}]
  end

  # -- S61.3  unknown capability referenced by plan --
  defp pos(:unknown_capability_referenced_by_plan) do
    [{ex("planStep1"), sa("usesCapability"), ex("capSendEmail")}]
  end

  # -- S61.4  unadmitted ontology term --
  defp pos(:unadmitted_ontology_term) do
    [{ex("artifact1"), sa("usesTerm"), ex("termSettlementWindow")}]
  end

  # -- S61.5  unadmitted rule --
  defp pos(:unadmitted_rule) do
    [{ex("planStep1"), sa("appliesRule"), ex("ruleEscalateOnBreach")}]
  end

  # -- S61.6  unadmitted validator --
  defp pos(:unadmitted_validator) do
    [{ex("artifact1"), sa("validatedBy"), ex("shapesPaymentV3")}]
  end

  # -- S61.7  plan exceeding fan-out bound --
  defp pos(:plan_exceeds_fanout_bound) do
    [
      {ex("plan1"), sa("fanOutBound"), {:int, 2}},
      {ex("plan1"), sa("hasSubStep"), ex("step1")},
      {ex("plan1"), sa("hasSubStep"), ex("step2")},
      {ex("plan1"), sa("hasSubStep"), ex("step3")}
    ]
  end

  # -- S61.8  plan exceeding resource envelope --
  defp pos(:plan_exceeds_resource_envelope) do
    [
      {ex("plan2"), sa("resourceBudget"), {:int, 10}},
      {ex("plan2"), sa("hasSubStep"), ex("stepA")},
      {ex("plan2"), sa("hasSubStep"), ex("stepB")},
      {ex("stepA"), sa("resourceCost"), {:int, 6}},
      {ex("stepB"), sa("resourceCost"), {:int, 7}}
    ]
  end

  # -- S61.9  semantic artifact lacking provenance --
  # Carries a canonicalDigest deliberately, so this fixture isolates F09 from F10.
  defp pos(:artifact_lacking_provenance) do
    [
      {ex("artifact2"), a(), sa("SemanticArtifact")},
      {ex("artifact2"), sa("canonicalDigest"), {:lit, "9b8180962a93910d17c51d029626f393d"}}
    ]
  end

  # -- S61.10 semantic artifact lacking canonical identity --
  # Carries provenance deliberately, so this fixture isolates F10 from F09.
  defp pos(:artifact_lacking_canonical_identity) do
    [
      {ex("artifact3"), a(), sa("SemanticArtifact")},
      {ex("artifact3"), prov("wasDerivedFrom"), ex("source1")}
    ]
  end

  # -- S61.11 projection attempting to become canonical source --
  defp pos(:projection_claiming_canonical_source) do
    [
      {ex("projection1"), sa("projectionOf"), ex("canonicalGraph1")},
      {ex("projection1"), a(), sa("CanonicalSource")}
    ]
  end

  # -- S61.12 authority derived from agent identity alone --
  defp pos(:authority_from_agent_identity_alone) do
    [
      {ex("grant1"), a(), sa("AuthorityGrant")},
      {ex("grant1"), sa("derivedFrom"), ex("agent1")},
      {ex("agent1"), a(), sa("AgentIdentity")}
    ]
  end

  # -- S61.13 LLM output marked directly as ADMITTED --
  defp pos(:llm_output_directly_admitted) do
    [
      {ex("llmOutput1"), sa("producedBy"), ex("llmActivity1")},
      {ex("llmActivity1"), a(), sa("LlmActivity")},
      {ex("llmOutput1"), sa("standing"), {:lit, "ADMITTED"}}
    ]
  end

  # -- S61.14 canonical mutation outside BRCE --
  defp pos(:canonical_mutation_outside_brce) do
    [{ex("mutation1"), a(), sa("CanonicalMutation")}]
  end

  # ==========================================================================
  # Negative fixtures: the same shape, condition repaired (falsifier does NOT trip).
  # ==========================================================================

  # -- S61.1  consequence without authority requirement --
  defp neg(:consequence_without_authority_requirement) do
    pos(:consequence_without_authority_requirement) ++
      [{ex("cmd1"), sa("requiresAuthority"), ex("ledgerWriteGrant")}]
  end

  # -- S61.2  DO without prepared-receipt requirement --
  defp neg(:do_without_prepared_receipt) do
    pos(:do_without_prepared_receipt) ++
      [{ex("do1"), sa("preparedReceipt"), ex("receiptAnchor1")}]
  end

  # -- S61.3  unknown capability referenced by plan --
  defp neg(:unknown_capability_referenced_by_plan) do
    pos(:unknown_capability_referenced_by_plan) ++
      [{ex("capSendEmail"), a(), sa("AdmittedCapability")}]
  end

  # -- S61.4  unadmitted ontology term --
  defp neg(:unadmitted_ontology_term) do
    pos(:unadmitted_ontology_term) ++
      [{ex("termSettlementWindow"), a(), sa("AdmittedTerm")}]
  end

  # -- S61.5  unadmitted rule --
  defp neg(:unadmitted_rule) do
    pos(:unadmitted_rule) ++ [{ex("ruleEscalateOnBreach"), a(), sa("AdmittedRule")}]
  end

  # -- S61.6  unadmitted validator --
  defp neg(:unadmitted_validator) do
    pos(:unadmitted_validator) ++ [{ex("shapesPaymentV3"), a(), sa("AdmittedValidator")}]
  end

  # -- S61.7  plan exceeding fan-out bound --
  defp neg(:plan_exceeds_fanout_bound) do
    [
      {ex("plan1"), sa("fanOutBound"), {:int, 2}},
      {ex("plan1"), sa("hasSubStep"), ex("step1")},
      {ex("plan1"), sa("hasSubStep"), ex("step2")}
    ]
  end

  # -- S61.8  plan exceeding resource envelope --
  defp neg(:plan_exceeds_resource_envelope) do
    [
      {ex("plan2"), sa("resourceBudget"), {:int, 10}},
      {ex("plan2"), sa("hasSubStep"), ex("stepA")},
      {ex("plan2"), sa("hasSubStep"), ex("stepB")},
      {ex("stepA"), sa("resourceCost"), {:int, 4}},
      {ex("stepB"), sa("resourceCost"), {:int, 5}}
    ]
  end

  # -- S61.9  semantic artifact lacking provenance --
  defp neg(:artifact_lacking_provenance) do
    pos(:artifact_lacking_provenance) ++
      [{ex("artifact2"), prov("wasDerivedFrom"), ex("source1")}]
  end

  # -- S61.10 semantic artifact lacking canonical identity --
  defp neg(:artifact_lacking_canonical_identity) do
    pos(:artifact_lacking_canonical_identity) ++
      [{ex("artifact3"), sa("canonicalDigest"), {:lit, "610ccbcd4ed4b23cf4179fde360625da"}}]
  end

  # -- S61.11 projection attempting to become canonical source --
  defp neg(:projection_claiming_canonical_source) do
    [{ex("projection1"), sa("projectionOf"), ex("canonicalGraph1")}]
  end

  # -- S61.12 authority derived from agent identity alone --
  defp neg(:authority_from_agent_identity_alone) do
    pos(:authority_from_agent_identity_alone) ++
      [
        {ex("grant1"), sa("derivedFrom"), ex("brokerDecision1")},
        {ex("brokerDecision1"), a(), sa("AuthorityBrokerDecision")}
      ]
  end

  # -- S61.13 LLM output marked directly as ADMITTED --
  defp neg(:llm_output_directly_admitted) do
    [
      {ex("llmOutput1"), sa("producedBy"), ex("llmActivity1")},
      {ex("llmActivity1"), a(), sa("LlmActivity")},
      {ex("llmOutput1"), sa("standing"), {:lit, "CANDIDATE"}}
    ]
  end

  # -- S61.14 canonical mutation outside BRCE --
  defp neg(:canonical_mutation_outside_brce) do
    pos(:canonical_mutation_outside_brce) ++
      [{ex("mutation1"), sa("viaCommandBus"), ex("commandBus1")}]
  end

  # ==========================================================================
  # RFC S18.4 fixtures -- graph classification for SPARQL Update targets
  # ==========================================================================

  @doc """
  A graph classifying one canonical graph IRI and one staging graph IRI, for
  RFC S18.4 `AshA2A.Semantic.FalsifierSuite.check_update/2` testing.
  """
  @spec update_classification() :: [tuple()]
  def update_classification do
    [
      {ex("canonicalGraph1"), a(), sa("CanonicalGraph")},
      {ex("stagingGraph1"), a(), sa("StagingGraph")}
    ]
  end

  @doc "The canonical graph IRI used by `update_classification/0`."
  def canonical_graph_iri, do: ex("canonicalGraph1")

  @doc "The staging graph IRI used by `update_classification/0`."
  def staging_graph_iri, do: ex("stagingGraph1")
end
