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
  an engine verdict rather than substitutes for one: it canonicalizes the
  candidate graph with RDF.ex's real RDFC-1.0 `RDF.Graph.canonical_hash/1` for
  RFC S12 identity (see the Identity stage), and it parses each law document to
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

  ## Telemetry

    * `[:ash_a2a, :semantic, :admission, :start]` -- metadata `%{candidate_digest: ...}`
    * `[:ash_a2a, :semantic, :admission, :stage]` -- one event per attempted
      stage, metadata `%{stage:, outcome: :ok | :refused, standing:, code:, determinacy:}`
    * `[:ash_a2a, :semantic, :admission, :stop]` -- metadata
      `%{outcome: :admitted | :refused, standing:, stage:, code:}`
  """

  alias AshA2A.GraphLaw.Wasm
  alias AshA2A.Semantic.{Admission, IR, LawDocument, Source}
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
  `:host_script`, `:node`, `:tmp_dir`).
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
        {:ok, engine} -> run_stages(candidate, engine, opts)
        {:error, %Refusal{} = refusal} -> {:error, emit_refusal(refusal)}
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

    calls = [
      {:validate_all, [candidate.graph_ttl <> @parse_witness, "", "", "", ""]},
      {:graph_hash, [candidate.graph_ttl]},
      {:validate_all,
       [
         law_graph,
         candidate.profile_ttl,
         candidate.shacl_shapes,
         candidate.shex_schema,
         candidate.shex_shape_map
       ]},
      {:graphlaw_version, []}
    ]

    with {:ok, [witness_raw, graph_hash, report_raw, version]} <- Wasm.batch(calls, opts),
         {:ok, witness} <- Wasm.decode_json(witness_raw),
         {:ok, report} <- Wasm.decode_json(report_raw) do
      {:ok,
       %{
         witness: witness,
         graph_hash: graph_hash,
         report: report,
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
  # RFC S12 canonical graph identity therefore comes from RDF.ex's real
  # RDFC-1.0 `RDF.Graph.canonical_hash/1`, which *is* blank-node-relabel
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
      require_dialect(engine.report, "SHEX", :shex, standing, :shex_nonconformant)
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
      require_dialect(engine.report, "SHACL", :shacl, standing, :shacl_nonconformant)
    end
  end

  # Stage 5 -- RuleClosure. The engine's Datalog/N3 forward closure must have
  # been computed and terminated; `triples_out` is recorded as evidence.
  defp run_stage(:rule_closure, _candidate, engine, standing) do
    require_dialect(engine.report, "DATALOG", :rule_closure, standing, :rule_closure_refused)
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
      require_dialect(engine.report, "OWL_RL", :profile_checks, standing, :profile_nonconformant)
    end
  end

  # --- stage helpers ----------------------------------------------------

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

  # RFC S12 canonical graph identity, in-BEAM, from RDF.ex's real RDFC-1.0
  # implementation. Unlike the wasm export this is blank-node-relabel invariant
  # and its reader refuses malformed Turtle rather than digesting the empty
  # graph, so a graph that cannot be canonicalized has no identity and the
  # stage refuses instead of inventing one.
  defp canonical_identity(%Candidate{graph_ttl: ttl}, standing) do
    case LawDocument.turtle_graph(ttl) do
      {:ok, graph} ->
        {:ok, %{canonical_graph_hash: RDF.Graph.canonical_hash(graph)}}

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
          "sa2a-admission-v2",
          engine.version,
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
           ir: provenance_ir(passed)
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
