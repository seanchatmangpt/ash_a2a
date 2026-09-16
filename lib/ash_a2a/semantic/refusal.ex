defmodule AshA2A.Semantic.Refusal do
  @moduledoc """
  RFC-SA2A-001 S42 refusal-class taxonomy for the semantic boundary.

  ## A refusal is a lawful outcome, not an error

  RFC S42 is explicit on this point and this module encodes it structurally:
  every `t:t/0` carries `lawful?: true`, and a refusal is something the
  boundary *produces on purpose* when the evidence required to proceed is
  absent, malformed, or insufficient. It is not an exception, not a crash,
  and not a bug report. "The system refused" and "the system failed" are
  different observations and must never be collapsed -- an unhandled crash
  is `:blocked_resource`/`BLOCKED_RESOURCE`, a lawfully withheld admission
  is one of the `REFUSED_*` classes, and an unmodelled situation is
  `BLOCKED_UNKNOWN` (which is *not* a refusal of the subject, only an
  admission that no classification exists yet).

  This is the S43 fail-closed posture: when in doubt the boundary refuses
  with a named class, it never proceeds on silence.

  ## The 18 classes

  Fifteen `REFUSED_*` classes, two `BLOCKED_*` classes, one `UNSUPPORTED_*`
  class:

    * `:refused_identity` -- the subject cannot be identified, or two
      identities that must be distinct collide (envelope id, request id,
      command dedup, continuation fingerprint, semantic-subject digest).
    * `:refused_namespace` -- a term, prefix, predicate, or object is
      outside the registered/closed namespace for this profile.
    * `:refused_structure` -- the payload's shape is wrong: missing fields,
      wrong arity, unparsable wire form, or a failed ShEx structural check.
    * `:refused_shacl` -- a real SHACL validation report is non-conformant.
    * `:refused_rule` -- a rule/derivation-level check refused the content
      (N3/Datalog entailment, content admissibility rules).
    * `:refused_falsifier` -- a declared falsifier actually fired.
    * `:refused_provenance` -- an assertion is not grounded in its declared
      source, or provenance is absent where it is required.
    * `:refused_profile` -- the declared profile is malformed or does not
      admit this envelope. (A profile that is well-formed but simply not
      implemented here is `:unsupported_profile`, not this.)
    * `:refused_plan` -- planning refused: no operators, no goal, a
      synthesis/compilation failure, or an inadmissible plan shape.
    * `:refused_capability` -- the named capability does not resolve, is not
      canonical, or has no projected action.
    * `:refused_authority` -- authority is required and absent, mismatched,
      or the authority ceiling for candidate-standing state was violated.
    * `:refused_consequence` -- consequence class is unclassified, or a
      consequence-bearing transition is barred (kill switch, not cancelable).
    * `:refused_receipt` -- a receipt could not be anchored, committed, or
      found, or a receipt identity required as evidence is missing.
    * `:refused_bounds` -- a declared bound (`bounds` on the envelope,
      resource ceilings) would be exceeded.
    * `:refused_meta_rigor` -- the *claim about rigor itself* fails: a
      standing asserted without the evidence that standing requires, a
      required predecessor skipped, standing inferred from a forbidden
      source, or standing self-declared by the sender.
    * `:blocked_unknown` -- no classification exists for this situation.
      `UNKNOWN != ADMITTED` and `UNKNOWN != REFUSED`: this records that the
      boundary does not know, which is itself a fail-closed stop.
    * `:blocked_resource` -- a real local resource is unavailable (a binary
      not built, a store down, a worker exit, a crash). The subject was
      never judged.
    * `:unsupported_profile` -- the profile is well-formed and legible but
      this runtime does not implement it. `UNSUPPORTED != REFUSED`.

  ## Mapping layer, not a migration

  `ash_a2a` already carries typed refusal codes across `AshA2A.CommandBus`,
  `AshA2A.Planning`, `AshA2A.Planning.GoalFacts`, `AshA2A.Semantic.Admission`,
  `AshA2A.SemanticSubject`, and the receipt/store layer. Those codes are
  load-bearing and directly asserted on by existing tests. This module does
  **not** rename, wrap, or replace any of them.

  `classify/1` is a total function from an existing native code to its S42
  class, and `from_error/2` lifts an existing `{:error, %{code: ..}}` /
  `{:error, atom}` / bare-atom refusal into a `t:t/0` while **preserving the
  original code verbatim** in the `:code` field. Callers that already match
  on `%{code: :authority_required}` keep working unchanged; callers that want
  the taxonomy ask for `.class`.

  `classify/1` is total by construction: every code present in `lib/` today
  is explicitly mapped (see `mapping/0`), and anything unmapped falls through
  to `:blocked_unknown` rather than raising -- because "I have no
  classification for this" is itself a real, honest, fail-closed answer, and
  a crash in the classifier would be a worse outcome than an admitted
  unknown.

  ## Fields

    * `:class` -- one of `classes/0`. The S42 taxonomy class.
    * `:code` -- the originating native code, preserved verbatim.
    * `:stage` -- the boundary stage that refused (conventionally one of
      `AshA2A.Semantic.Standing.states/0`, but any atom naming a real stage
      is accepted; the stage is evidence about *where*, not a second
      taxonomy).
    * `:detail` -- free term carrying the specific detail.
    * `:lawful?` -- always `true`. Present so that code reading a refusal
      cannot accidentally treat it as an exception without seeing the flag.
  """

  @refused_classes [
    :refused_identity,
    :refused_namespace,
    :refused_structure,
    :refused_shacl,
    :refused_rule,
    :refused_falsifier,
    :refused_provenance,
    :refused_profile,
    :refused_plan,
    :refused_capability,
    :refused_authority,
    :refused_consequence,
    :refused_receipt,
    :refused_bounds,
    :refused_meta_rigor
  ]

  @blocked_classes [:blocked_unknown, :blocked_resource]
  @unsupported_classes [:unsupported_profile]
  @classes @refused_classes ++ @blocked_classes ++ @unsupported_classes

  @enforce_keys [:class, :code, :stage]
  defstruct [:class, :code, :stage, :detail, lawful?: true]

  @type class ::
          :refused_identity
          | :refused_namespace
          | :refused_structure
          | :refused_shacl
          | :refused_rule
          | :refused_falsifier
          | :refused_provenance
          | :refused_profile
          | :refused_plan
          | :refused_capability
          | :refused_authority
          | :refused_consequence
          | :refused_receipt
          | :refused_bounds
          | :refused_meta_rigor
          | :blocked_unknown
          | :blocked_resource
          | :unsupported_profile

  @type t :: %__MODULE__{
          class: class(),
          code: atom(),
          stage: atom(),
          detail: term(),
          lawful?: true
        }

  # Total map from every native refusal code present in `lib/` (plus the
  # codes this semantic-envelope layer itself emits) to its S42 class.
  # Grouped by class, in the S42 order, so a reader can audit one class at
  # a time. Codes here are NEVER renamed -- this is a projection of the
  # existing vocabulary, not a replacement for it.
  @mapping %{
    # --- REFUSED_IDENTITY -------------------------------------------------
    semantic_identity_invalid: :refused_identity,
    semantic_source_mismatch: :refused_identity,
    invalid_request_id: :refused_identity,
    command_conflict: :refused_identity,
    unclaimed_command: :refused_identity,
    continuation_fingerprint_invalid: :refused_identity,
    refused_semantic_subject: :refused_identity,
    already_exists: :refused_identity,
    conflict: :refused_identity,
    in_flight: :refused_identity,
    envelope_id_missing: :refused_identity,

    # --- REFUSED_NAMESPACE ------------------------------------------------
    undeclared_predicate: :refused_namespace,
    undeclared_object: :refused_namespace,
    foreign_format: :refused_namespace,
    kind_namespace_unregistered: :refused_namespace,

    # --- REFUSED_STRUCTURE ------------------------------------------------
    semantic_fields_missing: :refused_structure,
    semantic_item_invalid: :refused_structure,
    semantic_goal_missing: :refused_structure,
    invalid_semantic_ir: :refused_structure,
    invalid_goal_facts: :refused_structure,
    ambiguous_goal_facts_shape: :refused_structure,
    invalid_fact_entry: :refused_structure,
    invalid_object_entry: :refused_structure,
    invalid_task_sequence_entry: :refused_structure,
    empty_task_sequence: :refused_structure,
    invalid_command_input: :refused_structure,
    invalid_phrase_template: :refused_structure,
    request_router_missing_input: :refused_structure,
    semantic_request_missing_text: :refused_structure,
    inconsistent_predicate_arity: :refused_structure,
    non_json_stdout: :refused_structure,
    bad_term: :refused_structure,
    kind_missing: :refused_structure,
    envelope_field_invalid: :refused_structure,
    envelope_payload_invalid: :refused_structure,
    envelope_json_invalid: :refused_structure,
    graph_shape_invalid: :refused_structure,
    standing_state_unknown: :refused_structure,
    # `AshA2A.Semantic.AdmissionPipeline`'s Identity stage: the engine
    # validated twice against fresh stores and the two canonical digests
    # disagreed, or no replay block was reported at all. A judgement that
    # does not replay identically has no stable identity to be about.
    replay_disagreement: :refused_identity,
    replay_missing: :refused_identity,
    # `AshA2A.Semantic.LawDocument`: a law document whose *shape* is wrong.
    # RDF.ex refused to parse the Turtle, or the ShExJ was not JSON / not an
    # object / declared no shapes. All structural, none of them a statement
    # about the subject graph.
    turtle_not_parseable: :refused_structure,
    shex_schema_not_json: :refused_structure,
    shex_schema_not_an_object: :refused_structure,
    shex_schema_has_no_shapes_key: :refused_structure,
    shex_shape_map_not_json: :refused_structure,
    shex_shape_map_not_a_list: :refused_structure,

    # --- REFUSED_SHACL ----------------------------------------------------
    # No native producer exists in `lib/` yet: SHACL validation is
    # GraphLaw's job (`validate_all/5`) and is not wired into this layer.
    # The class is defined so the wiring has a landing site, and so the
    # taxonomy is complete rather than partial.

    # --- REFUSED_RULE -----------------------------------------------------
    real_named_entity_not_admissible: :refused_rule,

    # --- REFUSED_FALSIFIER ------------------------------------------------
    # No native producer yet -- falsifier execution is not implemented in
    # this layer. Declared, not claimed.

    # --- REFUSED_PROVENANCE -----------------------------------------------
    ungrounded_assertion: :refused_provenance,

    # --- REFUSED_PROFILE --------------------------------------------------
    profile_invalid: :refused_profile,

    # --- REFUSED_PLAN -----------------------------------------------------
    no_hddl_operators: :refused_plan,
    no_canonical_capabilities: :refused_plan,
    semantic_replan_failed: :refused_plan,
    semantic_compilation_failed: :refused_plan,
    semantic_synthesis_failed: :refused_plan,
    invalid_semantic_plan_shape: :refused_plan,
    unexpected_planner_result: :refused_plan,
    unsupported_planner: :refused_plan,

    # --- REFUSED_CAPABILITY -----------------------------------------------
    capability_not_found: :refused_capability,
    action_not_found: :refused_capability,
    skill_not_found: :refused_capability,
    noncanonical_capability: :refused_capability,
    planner_capability_projection_missing: :refused_capability,

    # --- REFUSED_AUTHORITY ------------------------------------------------
    authority_required: :refused_authority,
    authority_mismatch: :refused_authority,
    authority_grant_not_admissible: :refused_authority,
    semantic_authority_ceiling_violated: :refused_authority,
    semantic_package_authority_ceiling_violated: :refused_authority,
    planner_authority_ceiling_violated: :refused_authority,
    authority_requirement_unknown: :refused_authority,

    # --- REFUSED_CONSEQUENCE ----------------------------------------------
    consequence_unclassified: :refused_consequence,
    kill_switch_tripped: :refused_consequence,
    not_cancelable: :refused_consequence,
    consequence_class_unknown: :refused_consequence,

    # --- REFUSED_RECEIPT --------------------------------------------------
    receipt_anchor_unavailable: :refused_receipt,
    receipt_commit_failed: :refused_receipt,
    receipt_commit_pending: :refused_receipt,
    receipt_not_completed: :refused_receipt,
    continuation_receipt_not_found: :refused_receipt,

    # --- REFUSED_BOUNDS ---------------------------------------------------
    max_children: :refused_bounds,
    standing_bounds_exceeded: :refused_bounds,

    # --- REFUSED_META_RIGOR -----------------------------------------------
    # "You are claiming a standing you have not evidenced."
    ontology_requires_admitted_semantics: :refused_meta_rigor,
    planning_ir_requires_admitted_semantics: :refused_meta_rigor,
    standing_self_declared: :refused_meta_rigor,
    standing_history_declared: :refused_meta_rigor,
    standing_predecessor_skipped: :refused_meta_rigor,
    standing_inferred: :refused_meta_rigor,
    standing_terminal: :refused_meta_rigor,
    standing_evidence_missing: :refused_meta_rigor,
    standing_evidence_invalid: :refused_meta_rigor,
    standing_terminal_evidence_invalid: :refused_meta_rigor,
    # The `AshA2A.Semantic.Standing` evidence-ledger codes: an envelope
    # presenting a standing its own sealed history does not evidence.
    standing_ledger_absent: :refused_meta_rigor,
    standing_ledger_malformed: :refused_meta_rigor,
    standing_ledger_discontinuous: :refused_meta_rigor,
    standing_ledger_inconsistent: :refused_meta_rigor,
    standing_ledger_unsealed: :refused_meta_rigor,
    standing_evidence_too_deep: :refused_meta_rigor,
    # `AshA2A.Semantic.AdmissionStanding.advance/2` refusing a skipped,
    # repeated or regressing ladder step in the S13 admission pipeline.
    standing_transition_invalid: :refused_meta_rigor,

    # --- BLOCKED_UNKNOWN --------------------------------------------------
    not_found: :blocked_unknown,
    continuation_package_not_found: :blocked_unknown,
    unclassified_error: :blocked_unknown,
    # The GraphLaw engine did not answer the question that was asked: the
    # dialect entry is absent, or the report shape is not one this runtime
    # understands. That is `UNKNOWN`, not a refusal of the subject -- and,
    # per `AshA2A.Semantic.AdmissionPipeline`, still fail-closed.
    graphlaw_dialect_missing: :blocked_unknown,
    graphlaw_report_malformed: :blocked_unknown,
    graphlaw_unexpected_result: :blocked_unknown,

    # --- BLOCKED_RESOURCE -------------------------------------------------
    hddl_cli_not_built: :blocked_resource,
    not_compiled: :blocked_resource,
    missing_opt: :blocked_resource,
    enoent: :blocked_resource,
    semantic_worker_exit: :blocked_resource,
    receipt_store_unavailable: :blocked_resource,
    dispatch_crashed: :blocked_resource,
    # `AshA2A.GraphLaw.Wasm` transport: the real engine could not be reached
    # or did not run. A missing artifact, a missing host script, no `node`, a
    # non-zero host exit, or non-JSON output are all resource conditions --
    # the subject was never judged, so none of them may be read as a verdict
    # about it.
    graphlaw_wasm_not_found: :blocked_resource,
    graphlaw_host_script_not_found: :blocked_resource,
    node_executable_not_found: :blocked_resource,
    graphlaw_host_exit: :blocked_resource,
    graphlaw_host_error: :blocked_resource,
    graphlaw_host_non_json: :blocked_resource,
    graphlaw_host_unexpected: :blocked_resource,
    graphlaw_non_json_result: :blocked_resource,
    graphlaw_result_arity: :blocked_resource,
    graphlaw_request_not_encodable: :blocked_resource,
    graphlaw_engine_error: :blocked_resource,

    # --- UNSUPPORTED_PROFILE ----------------------------------------------
    unknown_profile: :unsupported_profile
  }

  @doc "All 18 S42 classes, in RFC order."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "The fifteen `REFUSED_*` classes."
  @spec refused_classes() :: [class()]
  def refused_classes, do: @refused_classes

  @doc "The two `BLOCKED_*` classes."
  @spec blocked_classes() :: [class()]
  def blocked_classes, do: @blocked_classes

  @doc "The `UNSUPPORTED_*` classes."
  @spec unsupported_classes() :: [class()]
  def unsupported_classes, do: @unsupported_classes

  @doc "True when `value` is a real S42 class."
  @spec class?(term()) :: boolean()
  def class?(value), do: value in @classes

  @doc """
  The full native-code -> S42-class mapping.

  Exposed so a drift test can assert that every refusal code actually
  present in `lib/` is explicitly classified rather than silently falling
  through to `:blocked_unknown`.

  The table above is merged over codes contributed by provider modules: any
  compiled `:ash_a2a` module exporting `__sa2a_refusal_codes__/0` (every
  `AshA2A.Chicago.Court` does, via its `refusal_codes/0` callback). New
  subsystems classify their own codes without editing this table; entries
  naming a non-taxonomy class are ignored, and this table wins on conflict.
  """
  @spec mapping() :: %{atom() => class()}
  def mapping, do: Map.merge(provided_mapping(), @mapping)

  @doc """
  Total classification of a native refusal code into its S42 class.

  Unmapped codes classify as `:blocked_unknown` -- an honest "no
  classification exists" rather than a raise.

      iex> AshA2A.Semantic.Refusal.classify(:authority_required)
      :refused_authority

      iex> AshA2A.Semantic.Refusal.classify(:hddl_cli_not_built)
      :blocked_resource

      iex> AshA2A.Semantic.Refusal.classify(:no_such_code_anywhere)
      :blocked_unknown
  """
  @spec classify(atom()) :: class()
  def classify(code) when is_atom(code) do
    case Map.fetch(@mapping, code) do
      {:ok, class} -> class
      :error -> Map.get(provided_mapping(), code, :blocked_unknown)
    end
  end

  # Provider codes, cached per compiled module set (a recompile that adds or
  # removes modules changes the key and refreshes the cache).
  defp provided_mapping do
    modules = List.wrap(Application.spec(:ash_a2a, :modules))
    key = {__MODULE__, :provided_mapping, :erlang.phash2(modules)}

    case :persistent_term.get(key, nil) do
      nil ->
        provided =
          modules
          |> Enum.filter(
            &(Code.ensure_loaded?(&1) and function_exported?(&1, :__sa2a_refusal_codes__, 0))
          )
          |> Enum.flat_map(&Map.to_list(&1.__sa2a_refusal_codes__()))
          |> Enum.filter(fn {code, class} -> is_atom(code) and class in @classes end)
          |> Map.new()

        :persistent_term.put(key, provided)
        provided

      provided ->
        provided
    end
  end

  @doc """
  Builds a refusal with an explicit class.

  Raises `ArgumentError` on an unknown class or a non-atom code/stage --
  those are programmer errors in the refusing code itself, not runtime
  refusals of a subject, and must not be silently absorbed.
  """
  @spec new(class(), atom(), atom(), term()) :: t()
  def new(class, code, stage, detail \\ nil)

  def new(class, code, stage, detail)
      when class in @classes and is_atom(code) and is_atom(stage) do
    %__MODULE__{class: class, code: code, stage: stage, detail: detail}
  end

  def new(class, code, stage, _detail) do
    raise ArgumentError,
          "invalid AshA2A.Semantic.Refusal #{inspect({class, code, stage})}; " <>
            "class must be one of #{inspect(@classes)} and code/stage must be atoms"
  end

  @doc """
  Lifts an existing `ash_a2a` refusal into the S42 taxonomy without
  renaming it.

  Accepts every refusal shape already in use in this codebase:

    * `%AshA2A.Semantic.Refusal{}` -- returned as-is (stage filled in if it
      was `nil`).
    * `%{code: code}` (optionally with `:detail`) -- the `AshA2A.CommandBus`
      / `AshA2A.Planning` / `AshA2A.Semantic.Admission` shape.
    * `{:error, inner}` -- unwrapped and re-dispatched.
    * `{:refused_semantic_subject, field}` -- the `AshA2A.SemanticSubject`
      shape.
    * a bare atom -- the `{:error, :not_found}` family.
    * anything else -- `:blocked_unknown` / `:unclassified_error`, carrying
      the original term as `:detail`.

      iex> alias AshA2A.Semantic.Refusal
      iex> r = Refusal.from_error(%{code: :authority_required, detail: "x"}, :authorize)
      iex> {r.class, r.code, r.stage, r.detail, r.lawful?}
      {:refused_authority, :authority_required, :authorize, "x", true}
  """
  @spec from_error(term(), atom()) :: t()
  def from_error(error, stage \\ :unspecified)

  def from_error(%__MODULE__{stage: nil} = refusal, stage), do: %{refusal | stage: stage}
  def from_error(%__MODULE__{} = refusal, _stage), do: refusal

  def from_error({:error, inner}, stage), do: from_error(inner, stage)

  def from_error({:refused_semantic_subject, field}, stage) when is_atom(field) do
    new(:refused_identity, :refused_semantic_subject, stage, field)
  end

  def from_error(%{code: code} = map, stage) when is_atom(code) do
    new(classify(code), code, stage, Map.get(map, :detail))
  end

  def from_error(code, stage) when is_atom(code) and not is_nil(code) do
    new(classify(code), code, stage, nil)
  end

  def from_error(other, stage) do
    new(:blocked_unknown, :unclassified_error, stage, other)
  end

  @doc """
  The terminal standing state this refusal lands the envelope in.

  `REFUSED_*` -> `:refused`, `BLOCKED_RESOURCE` -> `:blocked`,
  `BLOCKED_UNKNOWN` -> `:unknown`, `UNSUPPORTED_PROFILE` -> `:unsupported`.

      iex> AshA2A.Semantic.Refusal.terminal_standing(
      ...>   AshA2A.Semantic.Refusal.new(:blocked_resource, :enoent, :parse)
      ...> )
      :blocked
  """
  @spec terminal_standing(t()) :: :refused | :blocked | :unknown | :unsupported
  def terminal_standing(%__MODULE__{class: class}) when class in @refused_classes, do: :refused
  def terminal_standing(%__MODULE__{class: :blocked_resource}), do: :blocked
  def terminal_standing(%__MODULE__{class: :blocked_unknown}), do: :unknown
  def terminal_standing(%__MODULE__{class: :unsupported_profile}), do: :unsupported

  @doc "JSON-shaped serialization of a refusal (string keys, string values)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = refusal) do
    %{
      "class" => Atom.to_string(refusal.class),
      "code" => Atom.to_string(refusal.code),
      "stage" => Atom.to_string(refusal.stage),
      "detail" => detail_string(refusal.detail),
      "lawful" => refusal.lawful?
    }
  end

  defp detail_string(nil), do: nil
  defp detail_string(detail) when is_binary(detail), do: detail
  defp detail_string(detail) when is_atom(detail), do: Atom.to_string(detail)
  defp detail_string(detail), do: inspect(detail, limit: :infinity, printable_limit: :infinity)
end
