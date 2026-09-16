defmodule AshA2A.Semantic.AdmissionPipeline do
  @moduledoc """
  RFC-SA2A-001 S13 ordered semantic admission pipeline, orchestrating the real
  `praxis-graphlaw` engine through `AshA2A.GraphLaw.Wasm`.

      Candidate -> Parse -> Identity -> ShEx -> SHACL -> RuleClosure
                -> SPARQLFalsifiers -> Provenance -> ProfileChecks -> ADMITTED

  This module contains **no conformance logic**. It does not evaluate SHACL, it
  does not evaluate ShEx, it does not compute a rule closure, and it does not
  decide whether a falsifier fired. Every one of those determinations is made
  by the real GraphLaw wasm; this module's job is ordering the stages,
  interpreting what the engine actually returned, advancing standing, refusing
  fail-closed, and emitting telemetry.

  Two things it *does* do with real RDF, both of them prerequisites for reading
  an engine verdict rather than substitutes for one: it takes the candidate
  graph's RFC S12 identity from `AshA2A.Semantic.CanonicalGraph` -- the one
  authoritative RDFC-1.0/SHA-256 primitive, over RDF.ex -- (see the Identity
  stage), and it parses each law document to
  count the obligations it declares (see non-vacuity below, and
  `AshA2A.Semantic.LawDocument`).

  ## Fail-closed, including "could not determine" (RFC S43)

  Every required stage is fail-closed. Critically, a stage that could not be
  *decided* refuses exactly like a stage that was decided against:

    * GraphLaw reports `UNSUPPORTED` for SHACL/ShEx when no shapes or schema
      were supplied. That is **not** a pass -- it means nothing was checked.
      This pipeline refuses with `determinacy: :undetermined`.
    * GraphLaw reports `PROFILE_NOT_ADMITTED` for OWL_RL when no profile was
      supplied. Same treatment.
    * A missing dialect entry, an engine error, a host failure, or an absent
      wasm artifact all refuse rather than skip.
    * A falsifier set that is empty is refused (`:falsifiers_not_supplied`):
      running zero falsifiers and finding zero violations determines nothing.

  ## Non-vacuity: a law document must actually assert something (RFC S43)

  Fail-closed used to be guarded by a *blankness* test on each law document,
  and three real, reproduced defects came out of that gap. A law document that
  is non-blank but asserts nothing produces a vacuous engine `ADMITTED`, and a
  blankness test reads that as "the predicate was determined to hold":

    * `profile_ttl: "@@@ not turtle at all ;;; <<<"` -- not blank, parses to
      zero profile axioms, OWL_RL `ADMITTED`, pipeline previously returned
      `{:ok, standing: :admitted}`.
    * `falsifiers: "#"` -- one comment, zero rules. A candidate carrying
      `ex:b a ex:Forbidden`, which the real falsifier set positively
      **refuses**, was previously admitted.
    * `shacl_shapes: "#"` -- zero shapes, so zero targets, so `0 violations`.
      A graph the real shapes refuse was previously admitted.

  Every law-bearing stage now parses its document and requires it to declare at
  least one checkable obligation before the engine's verdict is allowed to
  count as a determination: at least one SHACL shape, at least one ShEx shape
  *and* at least one shape-map binding, at least one OWL/RDFS profile axiom, at
  least one N3 implication. Unparseable and zero-obligation documents both
  refuse with `determinacy: :undetermined`. The counting lives in
  `AshA2A.Semantic.LawDocument`; conformance itself is still decided only by
  the real engine.

  ## Parse is a real witness, not an assumption

  Measured behaviour of this engine: `graph_hash/1` happily returns a hash for
  input that is not Turtle at all, and `validate_all/5` reports SHACL
  `ADMITTED -- 0 violations` over such input because there is nothing to target.
  So "a hash came back" and "no violations" would both silently pass garbage.

  The Parse stage therefore uses an engine-native witness: it appends the
  universal denial rule `{ ?s ?p ?o } => false .` and requires the engine's
  `N3_DENIAL` dialect to come back `REFUSED` with at least one violation --
  which happens iff the parsed graph really contains at least one triple.
  Measured: a well-formed graph yields 1 denial violation; an empty document,
  a prefix-only document, an unterminated statement, and arbitrary non-Turtle
  text all yield 0.

  ## Composition with `AshA2A.Semantic.Admission` (not replacement)

  `AshA2A.Semantic.Admission` already performs real, deterministic, structural
  gating over an extracted `AshA2A.Semantic.IR`: the authority fence
  (`standing: :candidate, authority: :none`), source identity match, required
  fields, unique ids, and the `source_quote` grounding check that structurally
  prevents an item asserting anything not verbatim present in the caller's own
  source text.

  That module **is** this pipeline's Provenance stage. `admit/2` calls it
  unchanged, through its existing `admit/2` API, and maps its existing error
  map onto a staged `AshA2A.Semantic.AdmissionRefusal`.
  Nothing about its behaviour or its existing tests changes: the graph-level engine stages sit *around* it,
  they do not duplicate or override it. A candidate that arrives without a
  provenance witness is refused (`:provenance_witness_missing`) rather than
  quietly skipping that check.

  ## The admitted set is an intersection (RFC S19)

  `required_stages/0` is the required predicate set. A run reaches `:admitted`
  only when the set of stages that actually returned `:ok` is *equal* to that
  set -- checked structurally at the end, in addition to each stage's own
  fail-closed guard, so an added-but-unwired stage cannot silently widen what
  counts as admitted. `AshA2A.Semantic.AdmissionStanding.advance/2` is
  single-step and monotonic, so no stage can be skipped on the way to `:admitted` either.

  ## Admission produces standing, never permission (RFC S4.2/S28)

  `Result.authority` is always `:none` and there is no code path that sets it
  otherwise. Reaching `:admitted` is evidence that a finite set of predicates
  was checked by a real engine and held. It confers no capability, authorises
  no command, and is not consulted as permission anywhere -- consequence stays
  behind `AshA2A.Authority` and `AshA2A.CommandBus`.

  ## Canonical state is unchanged by a refusal (RFC S44)

  `admit/2` performs no writes at all: no store, no file, no process state. A
  refusal at any stage therefore leaves canonical state byte-identical, which
  `test/ash_a2a/semantic_admission_pipeline_test.exs` proves with a real
  before/after canonical digest comparison rather than by inspection.

  ## SHACL severity: warnings never override, and never masquerade as, a violation (RFC S15)

  The pinned engine reports SHACL `REFUSED` for *any* result, whatever its
  `sh:severity`. When the shapes graph declares `sh:Warning`/`sh:Info` shapes,
  the one engine batch also validates against the violations-only partition
  from `AshA2A.Semantic.ShaclSeverity`: the SHACL stage passes a full-law
  `REFUSED` only when the violations-only run `ADMITTED`. A violation together
  with a warning still refuses; an unpartitionable shapes graph, or an engine
  error on the partition run, keeps full-report semantics and refuses.

  ## Law standing: a validator without standing cannot validate (RFC-SA2A-001 S20)

  Non-vacuity proves a law document asserts something; it does not prove the
  document is ADMITTED law. A candidate carries its own law documents, so
  without a standing check a candidate could bring the judge: a self-serving
  shapes graph admits a SHACL-invalid DO step, and an extra N3 rule appended to
  the falsifier set derives the missing obligation (both measured, CHI-ADM-005
  and CHI-ADM-006 in `AshA2A.Chicago.Courts.ExecutableWorld`).

  Every law-bearing stage therefore requires, once the engine has reported
  `ADMITTED`, that each document it was judged under has standing through
  `AshA2A.Semantic.MetaAdmission.document_standing/4` against the verified
  Root Manifest (`opts[:root_manifest]`, default the committed manifest):

  | stage             | documents (kind)                                   |
  |-------------------|----------------------------------------------------|
  | `:shex`           | `shex_schema` (`shex_schema`), `shex_shape_map` (`shex_shape_map`) |
  | `:shacl`          | `shacl_shapes` (`shacl_shapes`)                    |
  | `:rule_closure`   | `falsifiers`, when non-blank (`n3_rules`)          |
  | `:profile_checks` | `profile_ttl` (`semantic_profile`)                 |

  A document without standing refuses that stage `:law_without_standing`
  (`determinacy: :undetermined` -- an unadmitted judge determines nothing); a
  manifest that cannot be loaded refuses `:root_manifest_unavailable`. A
  REFUSED verdict stays a refusal whatever the law's standing. The admission
  digest binds the Root Manifest digest (`Result.root_manifest_digest`).

  The Root Manifest is host configuration, like `:wasm_path`: a candidate
  cannot supply it, and it is re-verified against its pinned files, engine and
  components at every use (`AshA2A.Semantic.RootManifest.verify_use/2`).

  ## Telemetry

    * `[:ash_a2a, :semantic, :admission, :start]` -- metadata `%{candidate_digest: ...}`
    * `[:ash_a2a, :semantic, :admission, :stage]` -- one event per attempted
      stage, metadata `%{stage:, outcome: :ok | :refused, standing:, code:, determinacy:}`
    * `[:ash_a2a, :semantic, :admission, :stop]` -- metadata
      `%{outcome: :admitted | :refused, standing:, stage:, code:}`
  """

  alias AshA2A.GraphLaw.Wasm

  alias AshA2A.Semantic.{
    Admission,
    CanonicalGraph,
    IR,
    LawDocument,
    MetaAdmission,
    RootManifest,
    ShaclSeverity,
    Source
  }

  alias AshA2A.Semantic.AdmissionRefusal, as: Refusal
  alias AshA2A.Semantic.AdmissionStanding, as: Standing

  @parse_witness "\n{ ?s ?p ?o } => false .\n"

  @stage_standing [
    parse: :parsed,
    identity: :identified,
    shex: :shex_conformant,
    shacl: :shacl_conformant,
    rule_closure: :closed,
    sparql_falsifiers: :falsifiers_clear,
    provenance: :provenance_grounded,
    profile_checks: :profile_conformant
  ]

  @required_stages Keyword.keys(@stage_standing)

  @refusal_codes %{
    law_without_standing: :refused_meta_rigor,
    root_manifest_unavailable: :refused_meta_rigor
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  defmodule Candidate do
    @moduledoc """
    One candidate graph plus the law it asks to be judged against.

    Every law field is required in the sense that omitting it produces a
    refusal, not a skipped check -- `AshA2A.Semantic.AdmissionPipeline`'s
    fail-closed rule (RFC S43). They are struct fields rather than positional
    arguments so that "what law was this judged under" is a single inspectable
    value that can be hashed into the admission receipt.
    """

    @enforce_keys [:graph_ttl]
    defstruct graph_ttl: nil,
              profile_ttl: "",
              shacl_shapes: "",
              shex_schema: "",
              shex_shape_map: "",
              falsifiers: "",
              expected_graph_hash: nil,
              provenance: nil

    @type t :: %__MODULE__{
            graph_ttl: String.t(),
            profile_ttl: String.t(),
            shacl_shapes: String.t(),
            shex_schema: String.t(),
            shex_shape_map: String.t(),
            falsifiers: String.t(),
            expected_graph_hash: String.t() | nil,
            provenance: {AshA2A.Semantic.Source.t(), AshA2A.Semantic.IR.t()} | nil
          }
  end

  defmodule Result do
    @moduledoc """
    The outcome of a successful admission run.

    `authority` is always `:none`: admission produces standing, never
    permission (RFC S4.2/S28).
    """

    @enforce_keys [:standing, :graph_hash, :stages, :admission_digest, :engine_version]
    defstruct [
      :standing,
      :graph_hash,
      :canonical_graph_hash,
      :law_graph_hash,
      :profile_hash,
      :stages,
      :admission_digest,
      :engine_version,
      :ir,
      :root_manifest_digest,
      authority: :none
    ]

    @type t :: %__MODULE__{
            standing: AshA2A.Semantic.AdmissionStanding.t(),
            graph_hash: String.t(),
            canonical_graph_hash: String.t() | nil,
            law_graph_hash: String.t() | nil,
            profile_hash: String.t() | nil,
            stages: [atom()],
            admission_digest: String.t(),
            engine_version: String.t(),
            ir: AshA2A.Semantic.IR.t() | nil,
            root_manifest_digest: String.t() | nil,
            authority: :none
          }
  end

  @doc """
  The RFC S19 required predicate set, in RFC S13 order. Reaching `:admitted`
  requires the set of passed stages to equal this set exactly.
  """
  @spec required_stages() :: [atom()]
  def required_stages, do: @required_stages

  @doc "The standing each stage advances to when it passes."
  @spec stage_standing() :: keyword()
  def stage_standing, do: @stage_standing

  @doc """
  The universal denial rule used as the Parse stage's engine-native
  triple-existence witness. Exposed so a test can assert on the real witness
  rather than restating it.
  """
  @spec parse_witness() :: String.t()
  def parse_witness, do: @parse_witness

  @doc """
  Runs the ordered S13 pipeline over `candidate` against the real GraphLaw
  engine.

  Returns `{:ok, %Result{}}` only when every required stage was positively
  determined to hold, or `{:error, %AshA2A.Semantic.AdmissionRefusal{}}` naming the
  exact stage that refused and whether it was `:violated` or `:undetermined`.

  `opts` are passed through to `AshA2A.GraphLaw.Wasm` (`:wasm_path`,
  `:host_script`, `:node`, `:tmp_dir`). `:root_manifest` is the verified
  `AshA2A.Semantic.RootManifest` whose pins give the candidate's law documents
  standing (see "Law standing" in the moduledoc); default: the committed
  manifest, `RootManifest.load(RootManifest.default_path(), require_engine: false)`.
  """
  @spec admit(Candidate.t(), keyword()) :: {:ok, Result.t()} | {:error, Refusal.t()}
  def admit(%Candidate{} = candidate, opts \\ []) do
    :telemetry.execute(
      [:ash_a2a, :semantic, :admission, :start],
      %{system_time: System.system_time()},
      %{required_stages: @required_stages}
    )

    result =
      case engine_report(candidate, opts) do
        {:ok, engine} ->
          run_stages(candidate, Map.merge(engine, %{law: law_manifest(opts), opts: opts}), opts)

        {:error, %Refusal{} = refusal} ->
          {:error, emit_refusal(refusal)}
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :admission, :stop],
      %{system_time: System.system_time()},
      stop_metadata(result)
    )

    result
  end

  # --- engine transport -------------------------------------------------

  # One real wasm instantiation serves the whole run: the parse witness probe,
  # the bare-graph canonical identity, the full law-graph validation, and the
  # engine's own version string.
  defp engine_report(%Candidate{} = candidate, opts) do
    law_graph = law_graph(candidate)

    validate = fn shapes ->
      {:validate_all,
       [law_graph, candidate.profile_ttl, shapes, candidate.shex_schema, candidate.shex_shape_map]}
    end

    calls = [
      {:validate_all, [candidate.graph_ttl <> @parse_witness, "", "", "", ""]},
      {:graph_hash, [candidate.graph_ttl]},
      validate.(candidate.shacl_shapes),
      {:graphlaw_version, []}
    ]

    # RFC S15 severity partition (see `AshA2A.Semantic.ShaclSeverity`): only
    # issued when the shapes declare a partitionable sh:Warning/sh:Info shape.
    severity_calls =
      case blank?(candidate.shacl_shapes) || ShaclSeverity.violations_only(candidate.shacl_shapes) do
        {:ok, %{violations_only: shapes}} -> [validate.(shapes)]
        _ -> []
      end

    with {:ok, [witness_raw, graph_hash, report_raw, version | severity_raw]} <-
           Wasm.batch(calls ++ severity_calls, opts),
         {:ok, witness} <- Wasm.decode_json(witness_raw),
         {:ok, report} <- Wasm.decode_json(report_raw) do
      {:ok,
       %{
         witness: witness,
         graph_hash: graph_hash,
         report: report,
         violations_only_report: violations_only_report(severity_raw),
         version: version
       }}
    else
      {:error, detail} ->
        {:error,
         Refusal.undetermined(:parse, :graphlaw_engine_unavailable, Standing.initial(),
           detail: detail
         )}
    end
  end

  # An engine error on the partition run leaves no violations-only report, so
  # the SHACL stage keeps full-report semantics (refuses): fail-closed.
  defp violations_only_report([raw]) do
    case Wasm.decode_json(raw) do
      {:ok, report} -> report
      {:error, _} -> nil
    end
  end

  defp violations_only_report(_), do: nil

  defp law_graph(%Candidate{graph_ttl: graph, falsifiers: falsifiers}) do
    if blank?(falsifiers), do: graph, else: graph <> "\n" <> falsifiers
  end

  # --- ordered stages ---------------------------------------------------

  defp run_stages(candidate, engine, opts) do
    initial = {Standing.initial(), []}

    Enum.reduce_while(@required_stages, {:ok, initial}, fn stage, {:ok, {standing, passed}} ->
      case run_stage(stage, candidate, engine, standing) do
        {:ok, ir} ->
          case Standing.advance(standing, Keyword.fetch!(@stage_standing, stage)) do
            {:ok, next} ->
              emit_stage(stage, :ok, next, nil, nil)
              {:cont, {:ok, {next, [{stage, ir} | passed]}}}

            {:error, detail} ->
              {:halt,
               {:error,
                emit_refusal(
                  Refusal.undetermined(stage, :standing_transition_invalid, standing,
                    detail: detail
                  )
                )}}
          end

        {:error, %Refusal{} = refusal} ->
          {:halt, {:error, emit_refusal(refusal)}}
      end
    end)
    |> case do
      {:ok, {standing, passed}} -> finalize(candidate, engine, standing, passed, opts)
      {:error, %Refusal{}} = refusal -> refusal
    end
  end

  # Stage 1 -- Parse. Engine-native triple-existence witness (see moduledoc).
  defp run_stage(:parse, _candidate, %{witness: witness}, standing) do
    case Wasm.dialect(witness, "N3_DENIAL") do
      {:ok, %{"status" => "REFUSED", "triples_out" => count}} when count >= 1 ->
        {:ok, nil}

      {:ok, %{"status" => "ADMITTED"} = entry} ->
        # Zero denial violations under the universal denial rule means the
        # engine parsed zero triples: empty, prefix-only, truncated, or not
        # Turtle at all. Refusing here is what stops garbage from sailing
        # through SHACL as "0 violations".
        {:error, Refusal.violated(:parse, :parse_yielded_no_triples, standing, evidence: entry)}

      {:ok, entry} ->
        {:error,
         Refusal.undetermined(:parse, :parse_witness_inconclusive, standing, evidence: entry)}

      {:error, detail} ->
        {:error, Refusal.undetermined(:parse, :parse_witness_missing, standing, detail: detail)}
    end
  end

  # Stage 2 -- Identity. Engine digest availability, engine replay agreement, a
  # real RDFC-1.0 canonical identity from RDF.ex in-BEAM, and (when pinned) an
  # exact match against the caller's expected identity.
  #
  # The wasm `graph_hash/1` export is NOT full RDFC-1.0: measured, it is
  # invariant under prefix relabeling and triple reordering but *not* under
  # blank-node relabeling, and it returns the empty-graph digest
  # (`af1349b9...`, i.e. `blake3("")`) for input it could not parse at all.
  # RFC S12 canonical graph identity therefore comes from
  # `AshA2A.Semantic.CanonicalGraph.canonical_digest/1` (RDFC-1.0 over RDF.ex,
  # SHA-256 over code-point-sorted N-Quads, `algorithm_id/0`
  # "RDFC-1.0/SHA-256/n-quads-sorted"), which *is* blank-node-relabel
  # invariant and whose reader fails closed on garbage. Both are recorded: the
  # engine digest is what the engine judged, the canonical hash is the RFC S12
  # identity.
  defp run_stage(:identity, candidate, engine, standing) do
    cond do
      not is_binary(engine.graph_hash) or engine.graph_hash == "" ->
        {:error,
         Refusal.undetermined(:identity, :graph_hash_unavailable, standing,
           detail: engine.graph_hash
         )}

      true ->
        with :ok <- replay_or_refuse(engine.report, standing),
             {:ok, canonical} <- canonical_identity(candidate, standing),
             {:ok, nil} <- identity_pin(candidate, engine, standing) do
          {:ok, canonical}
        end
    end
  end

  # Stage 3 -- ShEx. Real ShEx conformance from the engine's SHEX dialect, but
  # only once the schema and shape map have been parsed and found to declare at
  # least one shape and at least one focus-node binding. A schema declaring zero
  # shapes constrains nothing; a shape map binding zero focus nodes checks
  # nothing.
  defp run_stage(:shex, candidate, engine, standing) do
    with :ok <-
           require_supplied(:shex, standing, :shex_schema_not_supplied, candidate.shex_schema),
         :ok <-
           require_supplied(
             :shex,
             standing,
             :shex_schema_not_supplied,
             candidate.shex_shape_map
           ),
         :ok <-
           non_vacuous(
             :shex,
             standing,
             LawDocument.shex_shape_count(candidate.shex_schema),
             :shex_schema_vacuous
           ),
         :ok <-
           non_vacuous(
             :shex,
             standing,
             LawDocument.shex_shape_map_count(candidate.shex_shape_map),
             :shex_shape_map_vacuous
           ) do
      engine.report
      |> require_dialect("SHEX", :shex, standing, :shex_nonconformant)
      |> with_law_standing(:shex, engine, standing, [
        {candidate.shex_schema, "shex_schema"},
        {candidate.shex_shape_map, "shex_shape_map"}
      ])
    end
  end

  # Stage 4 -- SHACL. Real SHACL conformance from the engine's SHACL dialect,
  # but only once the shapes graph has been parsed by RDF.ex and found to
  # declare at least one real shape. A shapes document that declares zero
  # shapes targets zero nodes, so its "0 violations" determines nothing.
  defp run_stage(:shacl, candidate, engine, standing) do
    with :ok <-
           require_supplied(:shacl, standing, :shacl_shapes_not_supplied, candidate.shacl_shapes),
         :ok <-
           non_vacuous(
             :shacl,
             standing,
             LawDocument.shacl_shape_count(candidate.shacl_shapes),
             :shacl_shapes_vacuous
           ) do
      verdict =
        if warning_only?(engine) do
          {:ok, nil}
        else
          require_dialect(engine.report, "SHACL", :shacl, standing, :shacl_nonconformant)
        end

      with_law_standing(verdict, :shacl, engine, standing, [
        {candidate.shacl_shapes, "shacl_shapes"}
      ])
    end
  end

  # Stage 5 -- RuleClosure. The engine's Datalog/N3 forward closure must have
  # been computed and terminated; `triples_out` is recorded as evidence.
  #
  # The rules closed here are the candidate's `falsifiers` document; a rule
  # without standing cannot derive canonical facts (RFC-SA2A-001 S20), so a
  # non-blank rule document must be pinned under `n3_rules`.
  defp run_stage(:rule_closure, candidate, engine, standing) do
    rules = if blank?(candidate.falsifiers), do: [], else: [{candidate.falsifiers, "n3_rules"}]

    engine.report
    |> require_dialect("DATALOG", :rule_closure, standing, :rule_closure_refused)
    |> with_law_standing(:rule_closure, engine, standing, rules)
  end

  # Stage 6 -- SPARQLFalsifiers. The candidate's falsifier rules are carried as
  # N3 denials over the law graph; the engine's N3_DENIAL dialect decides them.
  # An empty falsifier set determines nothing and is refused.
  defp run_stage(:sparql_falsifiers, candidate, engine, standing) do
    with :ok <-
           require_supplied(
             :sparql_falsifiers,
             standing,
             :falsifiers_not_supplied,
             candidate.falsifiers
           ),
         :ok <-
           non_vacuous(
             :sparql_falsifiers,
             standing,
             {:ok, LawDocument.n3_rule_count(candidate.falsifiers)},
             :falsifiers_vacuous
           ) do
      require_dialect(
        engine.report,
        "N3_DENIAL",
        :sparql_falsifiers,
        standing,
        :falsifier_violated
      )
    end
  end

  # Stage 7 -- Provenance. The existing `AshA2A.Semantic.Admission` module, run
  # unchanged: authority fence, source identity, required fields, unique ids,
  # and verbatim `source_quote` grounding.
  defp run_stage(
         :provenance,
         %Candidate{provenance: {%Source{} = source, %IR{} = ir}},
         _e,
         standing
       ) do
    case Admission.admit(source, ir) do
      {:ok, %IR{} = admitted} ->
        {:ok, admitted}

      {:error, detail} ->
        {:error,
         Refusal.violated(:provenance, :provenance_not_grounded, standing, detail: detail)}
    end
  end

  defp run_stage(:provenance, %Candidate{provenance: nil}, _engine, standing) do
    {:error, Refusal.undetermined(:provenance, :provenance_witness_missing, standing)}
  end

  defp run_stage(:provenance, %Candidate{provenance: other}, _engine, standing) do
    {:error,
     Refusal.undetermined(:provenance, :provenance_witness_malformed, standing, detail: other)}
  end

  # Stage 8 -- ProfileChecks. The engine's OWL_RL dialect against the supplied
  # profile. `PROFILE_NOT_ADMITTED` means no profile was supplied: undetermined.
  defp run_stage(:profile_checks, candidate, engine, standing) do
    with :ok <-
           require_supplied(
             :profile_checks,
             standing,
             :profile_not_supplied,
             candidate.profile_ttl
           ),
         :ok <-
           non_vacuous(
             :profile_checks,
             standing,
             LawDocument.owl_axiom_count(candidate.profile_ttl),
             :profile_vacuous
           ) do
      engine.report
      |> require_dialect("OWL_RL", :profile_checks, standing, :profile_nonconformant)
      |> with_law_standing(:profile_checks, engine, standing, [
        {candidate.profile_ttl, "semantic_profile"}
      ])
    end
  end

  # --- law standing (meta-admission) -------------------------------------

  defp law_manifest(opts) do
    case Keyword.fetch(opts, :root_manifest) do
      {:ok, %RootManifest{} = manifest} ->
        {:ok, manifest}

      {:ok, other} ->
        {:error, %{code: :REFUSED_MANIFEST_MALFORMED, detail: %{got: inspect(other, limit: 5)}}}

      :error ->
        RootManifest.load(RootManifest.default_path(), require_engine: false)
    end
  end

  # A stage's engine verdict is only a determination when every law document
  # it was judged under has standing. Checked after the verdict so a refusal by
  # the law stays a refusal (an unadmitted judge can take standing away, never
  # confer it); checked before `:ok` is returned so an unadmitted judge's
  # "admitted" never advances standing.
  defp with_law_standing({:ok, _} = passed, stage, engine, standing, documents) do
    Enum.reduce_while(documents, passed, fn {document, kind}, acc ->
      case law_document_standing(engine, document, kind) do
        {:ok, _pin} ->
          {:cont, acc}

        {:error, {code, refusal}} ->
          {:halt,
           {:error,
            Refusal.undetermined(stage, code, standing,
              detail: refusal,
              evidence: %{kind: kind, artifact_digest: RootManifest.digest_bytes(document)}
            )}}
      end
    end)
  end

  defp with_law_standing(refused, _stage, _engine, _standing, _documents), do: refused

  defp law_document_standing(%{law: {:ok, manifest}, opts: opts}, document, kind) do
    opts = Keyword.put(opts, :consumer, inspect(__MODULE__))

    case MetaAdmission.document_standing(manifest, document, kind, opts) do
      {:ok, pin} -> {:ok, pin}
      {:error, refusal} -> {:error, {:law_without_standing, refusal}}
    end
  end

  defp law_document_standing(%{law: {:error, refusal}}, _document, _kind),
    do: {:error, {:root_manifest_unavailable, refusal}}

  # --- stage helpers ----------------------------------------------------

  # RFC S15: every full-law SHACL result came from a sh:Warning/sh:Info shape
  # iff the full run REFUSED and the violations-only run of the same engine
  # over the same graph ADMITTED. Anything else -- no partition, an engine
  # error, a violations-only REFUSED -- keeps full-report semantics.
  defp warning_only?(%{report: report, violations_only_report: %{} = violations_only}) do
    match?({:ok, %{"status" => "REFUSED"}}, Wasm.dialect(report, "SHACL")) and
      match?({:ok, %{"status" => "ADMITTED"}}, Wasm.dialect(violations_only, "SHACL"))
  end

  defp warning_only?(_engine), do: false

  defp require_supplied(stage, standing, code, document) do
    if blank?(document) do
      {:error, Refusal.undetermined(stage, code, standing)}
    else
      :ok
    end
  end

  # RFC S43 made a parse rather than a string test: a law document only earns
  # the right to have its engine verdict read as a determination once it has
  # been parsed and found to declare at least one checkable obligation. Zero
  # declared obligations, and an unparseable document, are both *undetermined*
  # -- never a pass. `AshA2A.Semantic.LawDocument` does the parsing and the
  # counting; nothing about conformance itself is decided here.
  defp non_vacuous(stage, standing, counted, vacuous_code) do
    case counted do
      {:ok, count} when is_integer(count) and count >= 1 ->
        :ok

      {:ok, 0} ->
        {:error,
         Refusal.undetermined(stage, vacuous_code, standing, evidence: %{declared_obligations: 0})}

      {:error, %{code: code} = failure} ->
        {:error, Refusal.undetermined(stage, code, standing, detail: failure)}
    end
  end

  # The single point where an engine dialect verdict becomes a stage outcome.
  # `ADMITTED` is the only pass. `REFUSED` is a determined violation.
  # `UNSUPPORTED` / `PROFILE_NOT_ADMITTED` / anything else / a missing dialect
  # are all undetermined -- RFC S43: never read "could not check" as "passed".
  defp require_dialect(report, dialect, stage, standing, violation_code) do
    case Wasm.dialect(report, dialect) do
      {:ok, %{"status" => "ADMITTED"}} ->
        {:ok, nil}

      {:ok, %{"status" => "REFUSED"} = entry} ->
        {:error, Refusal.violated(stage, violation_code, standing, evidence: entry)}

      {:ok, %{"status" => status} = entry} when status in ~w(UNSUPPORTED PROFILE_NOT_ADMITTED) ->
        {:error,
         Refusal.undetermined(stage, :"#{String.downcase(dialect)}_undetermined", standing,
           evidence: entry
         )}

      {:ok, entry} ->
        {:error,
         Refusal.undetermined(stage, :dialect_status_unrecognised, standing, evidence: entry)}

      {:error, detail} ->
        {:error, Refusal.undetermined(stage, :dialect_missing, standing, detail: detail)}
    end
  end

  # The engine validates twice against fresh stores and reports both hashes.
  # Disagreement means the judgement is not replayable, so it is undetermined.
  defp replay_agreement(%{
         "replay" => %{"status" => "ADMITTED", "first_hash" => a, "second_hash" => b}
       })
       when is_binary(a) and a == b,
       do: :ok

  defp replay_agreement(%{"replay" => replay}),
    do: {:error, [code: :replay_disagreement, evidence: replay]}

  defp replay_agreement(_report), do: {:error, [code: :replay_missing]}

  defp replay_or_refuse(report, standing) do
    case replay_agreement(report) do
      :ok -> :ok
      {:error, opts} -> {:error, identity_refusal(standing, opts)}
    end
  end

  # RFC S12 canonical graph identity, in-BEAM, through the ONE authoritative
  # primitive `AshA2A.Semantic.CanonicalGraph` (RDFC-1.0 over RDF.ex). Unlike
  # the wasm export this is blank-node-relabel invariant and its reader
  # refuses malformed Turtle rather than digesting the empty graph, so a graph
  # that cannot be canonicalized has no identity and the stage refuses instead
  # of inventing one. The parse stays on `LawDocument.turtle_graph/1` so the
  # refusal detail keeps its existing `%{code: :turtle_not_parseable}` shape.
  defp canonical_identity(%Candidate{graph_ttl: ttl}, standing) do
    with {:ok, graph} <- LawDocument.turtle_graph(ttl),
         {:ok, digest} <- CanonicalGraph.canonical_digest(graph) do
      {:ok, %{canonical_graph_hash: digest}}
    else
      {:error, failure} ->
        {:error,
         Refusal.undetermined(:identity, :graph_not_canonicalizable, standing, detail: failure)}
    end
  end

  defp identity_refusal(standing, opts) do
    {code, opts} = Keyword.pop!(opts, :code)
    Refusal.undetermined(:identity, code, standing, opts)
  end

  defp identity_pin(%Candidate{expected_graph_hash: nil}, _engine, _standing), do: {:ok, nil}

  defp identity_pin(%Candidate{expected_graph_hash: expected}, %{graph_hash: actual}, standing) do
    if expected == actual do
      {:ok, nil}
    else
      {:error,
       Refusal.violated(:identity, :graph_identity_mismatch, standing,
         evidence: %{expected: expected, actual: actual}
       )}
    end
  end

  # --- completion -------------------------------------------------------

  # RFC S19 made structural: admitted iff the set of stages that actually
  # passed equals the required set exactly. This is a second, independent
  # guard on top of each stage's own fail-closed check -- a stage added to
  # `@required_stages` but never wired into `run_stage/4` cannot silently
  # widen what "admitted" means, and an early `:halt` cannot reach here.
  defp finalize(candidate, engine, standing, passed, opts) do
    passed_stages = passed |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    cond do
      not MapSet.equal?(MapSet.new(passed_stages), MapSet.new(@required_stages)) ->
        {:error,
         emit_refusal(
           Refusal.undetermined(:admitted, :required_predicate_set_incomplete, standing,
             evidence: %{passed: passed_stages, required: @required_stages}
           )
         )}

      true ->
        case Standing.advance(standing, Standing.terminal()) do
          {:ok, admitted} ->
            build_result(candidate, engine, admitted, passed_stages, passed, opts)

          {:error, detail} ->
            {:error,
             emit_refusal(
               Refusal.undetermined(:admitted, :standing_transition_invalid, standing,
                 detail: detail
               )
             )}
        end
    end
  end

  defp build_result(candidate, engine, admitted, passed_stages, passed, opts) do
    report = engine.report

    # The admission receipt identity is a real BLAKE3 digest computed *by the
    # engine* over the canonical tuple of what was judged and under what law --
    # not an Elixir-side hash of an Elixir term. Identical admissions on
    # different runtimes therefore produce an identical receipt identity.
    digest_input =
      Enum.join(
        [
          "sa2a-admission-v3",
          engine.version,
          root_manifest_digest(engine),
          engine.graph_hash,
          canonical_graph_hash(passed) || "",
          Map.get(report, "graph_hash", ""),
          Map.get(report, "profile_hash", ""),
          law_digest_input(candidate),
          Enum.map_join(passed_stages, ",", &Atom.to_string/1)
        ],
        "\n"
      )

    case Wasm.blake3_hex(digest_input, opts) do
      {:ok, digest} ->
        emit_stage(:admitted, :ok, admitted, nil, nil)

        {:ok,
         %Result{
           standing: admitted,
           authority: :none,
           graph_hash: engine.graph_hash,
           canonical_graph_hash: canonical_graph_hash(passed),
           law_graph_hash: Map.get(report, "graph_hash"),
           profile_hash: Map.get(report, "profile_hash"),
           stages: passed_stages,
           admission_digest: digest,
           engine_version: engine.version,
           ir: provenance_ir(passed),
           root_manifest_digest: root_manifest_digest(engine)
         }}

      {:error, detail} ->
        {:error,
         emit_refusal(
           Refusal.undetermined(:admitted, :admission_digest_unavailable, admitted,
             detail: detail
           )
         )}
    end
  end

  defp root_manifest_digest(%{law: {:ok, %RootManifest{digest: digest}}}), do: digest
  defp root_manifest_digest(_engine), do: ""

  defp law_digest_input(%Candidate{} = candidate) do
    Enum.join(
      [
        candidate.profile_ttl,
        candidate.shacl_shapes,
        candidate.shex_schema,
        candidate.shex_shape_map,
        candidate.falsifiers
      ],
      " "
    )
  end

  defp canonical_graph_hash(passed) do
    Enum.find_value(passed, fn
      {:identity, %{canonical_graph_hash: hash}} -> hash
      _ -> nil
    end)
  end

  defp provenance_ir(passed) do
    Enum.find_value(passed, fn
      {:provenance, %IR{} = ir} -> ir
      _ -> nil
    end)
  end

  # --- telemetry --------------------------------------------------------

  defp emit_refusal(%Refusal{} = refusal) do
    emit_stage(refusal.stage, :refused, refusal.standing, refusal.code, refusal.determinacy)
    refusal
  end

  defp emit_stage(stage, outcome, standing, code, determinacy) do
    :telemetry.execute(
      [:ash_a2a, :semantic, :admission, :stage],
      %{system_time: System.system_time()},
      %{
        stage: stage,
        outcome: outcome,
        standing: standing,
        code: code,
        determinacy: determinacy
      }
    )
  end

  defp stop_metadata({:ok, %Result{} = result}),
    do: %{outcome: :admitted, standing: result.standing, stage: :admitted, code: nil}

  defp stop_metadata({:error, %Refusal{} = refusal}),
    do: %{
      outcome: :refused,
      standing: refusal.standing,
      stage: refusal.stage,
      code: refusal.code
    }

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
