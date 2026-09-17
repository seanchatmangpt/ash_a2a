defmodule AshA2A.Chicago.Fixtures.BenchHarness.Ledger do
  @moduledoc """
  Real `:change` fixture resource for the RFC-SA2A-002 B5/B9 benchmarks
  (`AshA2A.Chicago.Bench.B5Authority`, `AshA2A.Chicago.Bench.B9OcelOverhead`).

  A genuine `Ash.Resource` on `Ash.DataLayer.Ets` with `extensions: [AshA2A]`
  and one real consequence-bearing skill (`:record_entry` -> `:create`), so the
  benchmarks drive the real `AshA2A.CommandBus` prepared-receipt, actuation and
  final-receipt path. Compiled in every environment (not `test/support`) so
  `mix ash_a2a.chicago.bench` and the discoverable court run outside the test
  suite. Post-state is read back with `Ash.read!/2` -- an independent reader,
  never the actuator's return value.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.BenchHarness.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, create: [:label]])
  end

  a2a do
    skill(:record_entry, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.BenchHarness.Domain do
  @moduledoc """
  Fixture domain for `AshA2A.Chicago.Fixtures.BenchHarness.Ledger`.
  `validate_config_inclusion?: false` opts this benchmark-only domain out of the
  host application's `ash_domains` inclusion check.
  """

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.BenchHarness.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.BenchHarness.AdmissionCorpus do
  @moduledoc """
  Real admission corpus for benchmark SA2A-B1 (RFC-SA2A-002 §85): one lawful
  candidate and five invalid candidates, each refused by a different real stage
  of `AshA2A.Semantic.AdmissionPipeline` running the real `praxis-graphlaw`
  wasm. Every input is real Turtle / SHACL / ShExJ / N3 / OWL text; no verdict
  is fabricated here -- each case only records the stage the real engine is
  expected to refuse at, which the benchmark checks as a semantic invariant on
  every iteration (§84).

  §85 requires invalid candidates in the corpus and forbids skipping them from
  cost reporting; the B1 benchmark reports them in the same latency and
  throughput distributions as the lawful case.

  The law mirrors the admission pipeline's own engine tests: ShEx requires
  `schema:description`; SHACL additionally requires `ex:owner`; the falsifier
  set denies any `ex:Forbidden`; provenance must quote the source verbatim.
  """

  alias AshA2A.Semantic.{IR, Source}
  alias AshA2A.Semantic.AdmissionPipeline.Candidate

  @conforming """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" ;
    ex:owner ex:sean .
  """

  @missing_description """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    ex:owner ex:sean .
  """

  @missing_owner """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" .
  """

  @forbidden """
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:a a ex:Goal ;
    schema:description "ship the admission pipeline" ;
    ex:owner ex:sean .
  ex:b a ex:Forbidden .
  """

  @not_turtle "this is not turtle at all <<< @@@ ;;;"

  @shacl_shapes """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://example.org/> .
  @prefix schema: <http://schema.org/> .
  ex:GoalShape a sh:NodeShape ;
    sh:targetClass ex:Goal ;
    sh:property [ sh:path schema:description ; sh:minCount 1 ] ;
    sh:property [ sh:path ex:owner ; sh:minCount 1 ] .
  """

  @shex_schema ~s({"shapes":[{"id":"http://example.org/GoalShEx","shapeExpr":{"type":"Shape","closed":false,"extra":[],"expression":{"type":"TripleConstraint","predicate":"http://schema.org/description","valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#string"},"min":1,"max":1}}}]})

  @shex_shape_map ~s([["http://example.org/a","http://example.org/GoalShEx"]])

  @profile """
  @prefix owl: <http://www.w3.org/2002/07/owl#> .
  @prefix ex: <http://example.org/> .
  ex:Goal a owl:Class .
  """

  @falsifiers """
  @prefix ex: <http://example.org/> .
  { ?s a ex:Forbidden } => false .
  """

  @source_text """
  The team agreed to ship the admission pipeline this week, with sean as owner.
  """

  @grounded_ir %{
    "authority" => "none",
    "goals" => [
      %{
        "id" => "goal-1",
        "kind" => "goal",
        "description" => "ship the admission pipeline",
        "source_quote" => "ship the admission pipeline"
      }
    ]
  }

  @ungrounded_ir %{
    "authority" => "none",
    "goals" => [
      %{
        "id" => "goal-1",
        "kind" => "goal",
        "description" => "delete the production database",
        "source_quote" => "delete the production database"
      }
    ]
  }

  @type expectation :: :admitted | {:refused, atom()}

  @type case_spec :: %{
          id: String.t(),
          valid?: boolean(),
          expect: expectation(),
          candidate: Candidate.t()
        }

  @doc """
  Pipeline options carrying a Root Manifest that pins this corpus's own law
  (ShEx schema, ShEx shape map, SHACL shapes, OWL profile, falsifier set)
  with standing (RFC-SA2A-001 S20/S21, RFC-SA2A-002 SA2A-META): every
  candidate in `cases/0` is judged under exactly this law, so one manifest
  covers the whole corpus. Built once per VM, over real files in a fresh
  directory, by `AshA2A.Semantic.RootManifest.LawCorpus.build/3` -- the same
  primitive `AshA2A.Test.SA2AAdmissionFixtures.law_opts/1` uses for the
  admission-pipeline unit tests. Without this, `AshA2A.Semantic.
  AdmissionPipeline.admit/2` falls back to the committed Root Manifest, which
  never pinned this benchmark's ad hoc law, and every case refuses at `:shex`
  with `:law_without_standing` before its own expected stage is ever reached.
  """
  @spec law_opts() :: keyword()
  def law_opts do
    key = {__MODULE__, :law_manifest}

    manifest =
      case :persistent_term.get(key, nil) do
        nil ->
          root =
            Path.join(
              System.tmp_dir!(),
              "ash_a2a-bench-b1-law-#{System.unique_integer([:positive])}"
            )

          {:ok, manifest} =
            AshA2A.Semantic.RootManifest.LawCorpus.build(root, [
              {"shex_schema", @shex_schema},
              {"shex_shape_map", @shex_shape_map},
              {"shacl_shapes", @shacl_shapes},
              {"semantic_profile", @profile},
              {"n3_rules", @falsifiers}
            ])

          :persistent_term.put(key, manifest)
          manifest

        manifest ->
          manifest
      end

    [root_manifest: manifest]
  end

  @doc """
  The corpus. `expect` is `:admitted` or `{:refused, stage}` -- the stage the
  real pipeline must refuse at.
  """
  @spec cases() :: [case_spec()]
  def cases do
    [
      %{id: "valid-conforming", valid?: true, expect: :admitted, candidate: candidate()},
      %{
        id: "invalid-parse-not-turtle",
        valid?: false,
        expect: {:refused, :parse},
        candidate: candidate(graph_ttl: @not_turtle)
      },
      %{
        id: "invalid-shex-missing-description",
        valid?: false,
        expect: {:refused, :shex},
        candidate: candidate(graph_ttl: @missing_description)
      },
      %{
        id: "invalid-shacl-missing-owner",
        valid?: false,
        expect: {:refused, :shacl},
        candidate: candidate(graph_ttl: @missing_owner)
      },
      %{
        id: "invalid-falsifier-forbidden",
        valid?: false,
        expect: {:refused, :sparql_falsifiers},
        candidate: candidate(graph_ttl: @forbidden)
      },
      %{
        id: "invalid-provenance-ungrounded",
        valid?: false,
        expect: {:refused, :provenance},
        candidate: candidate(provenance: provenance(@ungrounded_ir))
      }
    ]
  end

  @doc "A lawful candidate over the conforming graph; `overrides` replace fields."
  @spec candidate(keyword()) :: Candidate.t()
  def candidate(overrides \\ []) do
    struct!(
      %Candidate{
        graph_ttl: @conforming,
        profile_ttl: @profile,
        shacl_shapes: @shacl_shapes,
        shex_schema: @shex_schema,
        shex_shape_map: @shex_shape_map,
        falsifiers: @falsifiers,
        provenance: provenance(@grounded_ir)
      },
      overrides
    )
  end

  @doc "The unparseable graph text (used by negative controls of the benchmark itself)."
  @spec not_turtle() :: String.t()
  def not_turtle, do: @not_turtle

  @doc """
  Content identity of `cases` (Appendix E fixture/corpus identity): sha256 over
  the canonical JSON of every case's id, expectation and law/candidate text.
  """
  @spec digest([case_spec()]) :: String.t()
  def digest(cases \\ cases()) do
    cases
    |> Enum.map(fn c ->
      %{
        "id" => c.id,
        "valid" => c.valid?,
        "expect" => expectation_to_string(c.expect),
        "candidate" => candidate_identity(c.candidate)
      }
    end)
    |> AshA2A.Chicago.Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "`:admitted` -> `\"admitted\"`; `{:refused, :shacl}` -> `\"refused@shacl\"`."
  @spec expectation_to_string(expectation()) :: String.t()
  def expectation_to_string(:admitted), do: "admitted"
  def expectation_to_string({:refused, stage}), do: "refused@#{stage}"

  defp candidate_identity(%Candidate{} = c) do
    {source_text, ir} =
      case c.provenance do
        {%Source{text: text}, %IR{} = ir} -> {text, Map.from_struct(ir)}
        nil -> {nil, nil}
      end

    %{
      "graph_ttl" => c.graph_ttl,
      "profile_ttl" => c.profile_ttl,
      "shacl_shapes" => c.shacl_shapes,
      "shex_schema" => c.shex_schema,
      "shex_shape_map" => c.shex_shape_map,
      "falsifiers" => c.falsifiers,
      "expected_graph_hash" => c.expected_graph_hash,
      "provenance_source" => source_text,
      "provenance_ir" => ir
    }
  end

  defp provenance(ir_map) do
    source = Source.new(@source_text, id: "sa2a-bench-b1-source")
    {:ok, ir} = IR.from_map(source.id, ir_map)
    {source, ir}
  end
end
