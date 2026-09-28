defmodule AshA2A.Semantic.PolicyPopulationRDF do
  @moduledoc """
  Public-vocabulary RDF projection of a candidate policy population.

  The structured query surface uses RDF, PROV-O, DCTERMS and SKOS only.
  SA2A-owned URNs identify ABox resources; they are never predicates/classes.
  One `rdf:value` JSON literal carries the lossless canonical transport map.
  Parse-back must reproduce the same population digest and root identity.
  """

  alias AshA2A.Semantic.PolicyPopulation
  alias AshA2A.Semantic.Serialize

  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @rdf_value "http://www.w3.org/1999/02/22-rdf-syntax-ns#value"
  @prov_entity "http://www.w3.org/ns/prov#Entity"
  @prov_specialization_of "http://www.w3.org/ns/prov#specializationOf"
  @prov_was_derived_from "http://www.w3.org/ns/prov#wasDerivedFrom"
  @dct_type "http://purl.org/dc/terms/type"
  @dct_identifier "http://purl.org/dc/terms/identifier"
  @dct_has_part "http://purl.org/dc/terms/hasPart"
  @dct_subject "http://purl.org/dc/terms/subject"
  @dct_extent "http://purl.org/dc/terms/extent"
  @dct_relation "http://purl.org/dc/terms/relation"
  @skos_concept "http://www.w3.org/2004/02/skos/core#Concept"
  @skos_notation "http://www.w3.org/2004/02/skos/core#notation"

  @allowed_predicate_prefixes [
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "http://www.w3.org/ns/prov#",
    "http://purl.org/dc/terms/",
    "http://www.w3.org/2004/02/skos/core#"
  ]

  @type triple :: %{subject: term(), predicate: term(), object: term()}

  @doc "Stable ABox IRI for one population."
  @spec population_iri(PolicyPopulation.t()) :: String.t()
  def population_iri(%PolicyPopulation{} = population) do
    "urn:sa2a:policy-population:" <> digest_hex(PolicyPopulation.digest(population))
  end

  @doc "Project the population into lossless public-vocabulary triples."
  @spec to_triples(PolicyPopulation.t()) :: [triple()]
  def to_triples(%PolicyPopulation{} = population) do
    root = population_iri(population)
    population_digest = PolicyPopulation.digest(population)

    base = [
      triple(root, @rdf_type, iri(@prov_entity)),
      triple(root, @dct_type, literal("policy_population")),
      triple(root, @dct_identifier, literal(population_digest)),
      triple(root, @rdf_value, literal(Jason.encode!(PolicyPopulation.to_map(population))))
    ]

    evidence =
      Enum.map(population.evidence_refs, fn evidence_ref ->
        triple(root, @prov_was_derived_from, iri(evidence_ref))
      end)

    members =
      population.members
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{phenotype: phenotype, weight: weight}, index} ->
        phenotype_digest = AshA2A.Semantic.PolicyPhenotype.digest(phenotype)

        member =
          "#{root}:member:#{index}:#{digest_hex(phenotype_digest)}"

        measurements =
          phenotype.condition
          |> Enum.sort()
          |> Enum.with_index()
          |> Enum.flat_map(fn {{axis, value}, measurement_index} ->
            concept = axis_iri(axis)

            measurement =
              "#{member}:measurement:#{measurement_index}"

            [
              triple(member, @dct_has_part, iri(measurement)),
              triple(measurement, @rdf_type, iri(@prov_entity)),
              triple(measurement, @dct_type, literal("temperament_measurement")),
              triple(measurement, @dct_subject, iri(concept)),
              triple(measurement, @dct_extent, literal(number(value))),
              triple(concept, @rdf_type, iri(@skos_concept)),
              triple(concept, @skos_notation, literal(axis))
            ]
          end)

        [
          triple(root, @dct_has_part, iri(member)),
          triple(member, @rdf_type, iri(@prov_entity)),
          triple(member, @dct_type, literal("policy_phenotype")),
          triple(member, @dct_identifier, literal(phenotype_digest)),
          triple(member, @prov_specialization_of, iri(phenotype.capability_iri)),
          triple(member, @dct_relation, literal(phenotype.policy_family)),
          triple(member, @dct_extent, literal(number(weight)))
        ] ++
          Enum.map(phenotype.evidence_refs, fn evidence_ref ->
            triple(member, @prov_was_derived_from, iri(evidence_ref))
          end) ++ measurements
      end)

    (base ++ evidence ++ members)
    |> Enum.uniq()
    |> Enum.sort_by(fn %{subject: subject, predicate: predicate, object: object} ->
      {inspect(subject), inspect(predicate), inspect(object)}
    end)
  end

  @doc "Serialize and independently parse-back verify the Turtle document."
  @spec to_turtle(PolicyPopulation.t()) :: {:ok, String.t()} | {:error, map()}
  def to_turtle(%PolicyPopulation{} = population) do
    triples = to_triples(population)

    with {:ok, document} <- Serialize.to_turtle(triples, compact: false),
         {:ok, _count} <- Serialize.verify(triples, document, format: :turtle) do
      {:ok, document}
    end
  end

  @doc "Reconstruct the exact population from the lossless RDF value triple."
  @spec from_triples([triple()], String.t() | nil) ::
          {:ok, PolicyPopulation.t()} | {:error, map()}
  def from_triples(triples, expected_digest \\ nil)

  def from_triples(triples, expected_digest) when is_list(triples) do
    roots =
      triples
      |> Enum.filter(fn triple ->
        triple.predicate == @dct_type and
          triple.object == literal("policy_population")
      end)
      |> Enum.map(& &1.subject)
      |> Enum.uniq()

    with [root] <- roots,
         [json] <- literal_objects(triples, root, @rdf_value),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, population} <- PolicyPopulation.from_map(decoded, expected_digest),
         :ok <- verify_root(root, population),
         :ok <- verify_public_vocabulary(triples) do
      {:ok, population}
    else
      {:error, _} = error -> error
      other -> {:error, %{code: :invalid_policy_population_rdf, detail: other}}
    end
  end

  def from_triples(other, _expected_digest),
    do: {:error, %{code: :invalid_policy_population_rdf, detail: other}}

  @doc "Refuse custom predicate/class semantics in this projection."
  @spec verify_public_vocabulary([triple()]) :: :ok | {:error, map()}
  def verify_public_vocabulary(triples) when is_list(triples) do
    predicate =
      Enum.find_value(triples, fn triple ->
        value = to_string(triple.predicate)

        if Enum.any?(@allowed_predicate_prefixes, &String.starts_with?(value, &1)),
          do: nil,
          else: value
      end)

    custom_class =
      Enum.find_value(triples, fn
        %{predicate: @rdf_type, object: {:iri, "urn:" <> _ = value}} -> value
        _ -> nil
      end)

    cond do
      predicate != nil ->
        {:error, %{code: :policy_population_custom_rdf_predicate, detail: predicate}}

      custom_class != nil ->
        {:error, %{code: :policy_population_custom_rdf_class, detail: custom_class}}

      true ->
        :ok
    end
  end

  defp verify_root(root, population) do
    expected = population_iri(population)

    if root == expected,
      do: :ok,
      else:
        {:error,
         %{
           code: :policy_population_rdf_identity_mismatch,
           expected: expected,
           actual: root
         }}
  end

  defp literal_objects(triples, subject, predicate) do
    Enum.flat_map(triples, fn
      %{subject: ^subject, predicate: ^predicate, object: {:literal, value}} -> [value]
      %{subject: ^subject, predicate: ^predicate, object: {:literal, value, []}} -> [value]
      _ -> []
    end)
  end

  defp triple(subject, predicate, object),
    do: %{subject: subject, predicate: predicate, object: object}

  defp iri(value), do: {:iri, value}
  defp literal(value), do: {:literal, value}

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: Float.to_string(value)

  defp digest_hex("sha256:" <> hex), do: hex
  defp digest_hex(other), do: other

  defp axis_iri(axis) do
    digest =
      :sha256
      |> :crypto.hash(axis)
      |> Base.encode16(case: :lower)

    "urn:sa2a:temperament-axis:" <> digest
  end
end
