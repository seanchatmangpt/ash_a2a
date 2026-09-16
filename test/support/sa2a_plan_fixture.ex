defmodule AshA2A.Test.SA2APlanFixture do
  @moduledoc """
  Real, shared fixture for the RFC-SA2A-001 S23/S24/S25/S26/S27/S48 tests.

  Nothing here is a mock, a stub, or a hand-set `standing: :admitted`. The
  admitted IR this returns went through the **real**
  `AshA2A.Semantic.Admission.admit/2` -- including its real `source_quote`
  grounding check against a real `AshA2A.Semantic.Source`'s real text, which
  is why every `"source_quote"` below is a verbatim substring of
  `@source_text`. Setting `standing: :admitted` by hand (as some older tests
  in this repo do) would make the S23 "only from admitted objects" claim
  untestable, because the admission that the claim is about would never have
  run.

  The domain mirrors `test/support/hddl/freedom_gym_meeting/`'s real
  phase-advance domain, so the plan package built from it and the real
  `hddl_cli` plan produced for it describe the same world.
  """

  alias AshA2A.Semantic.{Admission, IR, Ontology, PlanningIR, PlanProjection, Source}

  @source_text """
  The meeting opens and the facilitator must advance the room through every
  phase in order until it can close. The room starts at the open phase.
  The facilitator can advance the room from one phase to the next phase.
  Attendance may vary, so the room count is unclear at the start.
  No phase may be skipped.
  """

  @doc "The real source text every `source_quote` below is grounded in."
  @spec source_text() :: String.t()
  def source_text, do: @source_text

  @doc "A real `AshA2A.Semantic.Source` over `source_text/0`."
  @spec source() :: Source.t()
  def source, do: Source.new(@source_text, id: "sa2a-plan-fixture-src-1")

  @doc """
  A candidate (not yet admitted) IR over `source/0`. `admitted_ir/0` is what
  tests normally want; this exists so a test can exercise the real refusal
  path by feeding a genuinely candidate IR to something that requires an
  admitted one.
  """
  @spec candidate_ir() :: IR.t()
  def candidate_ir do
    %IR{
      source_id: source().id,
      standing: :candidate,
      authority: :none,
      entities: [
        %{
          "id" => "room",
          "kind" => "entity",
          "type" => "schema:Place",
          "label" => "the room",
          "description" => "the room being advanced through phases",
          "source_quote" => "the room"
        },
        %{
          "id" => "facilitator",
          "kind" => "entity",
          "type" => "schema:Person",
          "label" => "the facilitator",
          "description" => "the person advancing the room",
          "source_quote" => "the facilitator"
        }
      ],
      relations: [
        %{
          "id" => "rel-advance",
          "kind" => "relation",
          "subject" => "facilitator",
          "predicate" => "schema:agent",
          "object" => "room",
          "description" => "the facilitator advances the room",
          "source_quote" => "advance the room"
        }
      ],
      events: [],
      goals: [
        %{
          "id" => "goal-close",
          "kind" => "goal",
          "description" => "advance the room through every phase until it can close",
          "source_quote" => "advance the room through every"
        }
      ],
      constraints: [
        %{
          "id" => "constraint-order",
          "kind" => "constraint",
          "description" => "phases must be advanced in order",
          "source_quote" => "in order"
        }
      ],
      capabilities: [
        %{
          "id" => "cap-advance",
          "kind" => "capability",
          "description" => "advance the room from one phase to the next phase",
          "source_quote" => "advance the room from one phase to the next phase"
        }
      ],
      authorities: [],
      observations: [
        %{
          "id" => "obs-open",
          "kind" => "observation",
          "description" => "the room starts at the open phase",
          "source_quote" => "The room starts at the open phase"
        }
      ],
      uncertainties: [
        %{
          "id" => "unc-count",
          "kind" => "uncertainty",
          "description" => "the room count is unclear at the start",
          "source_quote" => "the room count is unclear"
        }
      ],
      exclusions: [
        %{
          "id" => "excl-skip",
          "kind" => "exclusion",
          "description" => "no phase may be skipped",
          "source_quote" => "No phase may be skipped"
        }
      ],
      temporal_relations: [],
      causal_hypotheses: [],
      unresolved: []
    }
  end

  @doc """
  The real admitted IR: `candidate_ir/0` run through the real
  `Admission.admit/2` against the real `source/0`. Raises (rather than
  returning an error tuple) if admission refuses, so a fixture that silently
  stopped being admissible fails loudly at the first test that uses it.
  """
  @spec admitted_ir() :: IR.t()
  def admitted_ir do
    case Admission.admit(source(), candidate_ir()) do
      {:ok, %IR{standing: :admitted} = ir} ->
        ir

      {:error, refusal} ->
        raise "SA2APlanFixture.admitted_ir/0 was refused by the real Admission.admit/2: " <>
                inspect(refusal)
    end
  end

  @doc "The real ontology projected from `admitted_ir/0`."
  @spec ontology() :: Ontology.t()
  def ontology do
    {:ok, ontology} = Ontology.from_ir(admitted_ir())
    ontology
  end

  @doc "The real planning IR projected from `admitted_ir/0` + `ontology/0`."
  @spec planning_ir() :: PlanningIR.t()
  def planning_ir do
    {:ok, planning} = PlanningIR.from_ir(admitted_ir(), ontology())
    planning
  end

  @doc "`{projection, ontology}` -- both real, and genuinely bound to each other."
  @spec projection() :: {PlanProjection.t(), Ontology.t()}
  def projection do
    ontology = ontology()
    {:ok, projection} = PlanProjection.from_admitted(planning_ir(), ontology)
    {projection, ontology}
  end

  @doc """
  Every option `PlanPackage.from_projection/3` needs to satisfy the
  `:strict` profile, as a keyword list a test can override one key of.

  The preconditions/effects use the same `{predicate, args}` fact shape
  `AshA2A.HddlOperator` declares and `AshA2A.Planning.HddlRenderer` renders,
  and name the same `advance`/`current-phase` vocabulary as the real
  `test/support/hddl/freedom_gym_meeting/domain.hddl`.
  """
  @spec strict_opts(keyword()) :: keyword()
  def strict_opts(overrides \\ []) do
    Keyword.merge(
      [
        profile: :strict,
        planning_domain_identity: "freedom-gym-meeting",
        method_identities: ["m-run-meeting"],
        action_identities: ["advance"],
        preconditions: [{:"current-phase", [:open]}],
        effects: [{:"current-phase", [:close]}],
        nondeterministic_outcomes: [],
        consequence_class: :change,
        required_capabilities: ["advance"],
        max_fan_out: 4,
        max_depth: 8,
        max_parallelism: 1,
        resource_envelope: %{
          max_wall_ms: 5_000,
          max_memory_bytes: 64_000_000,
          max_invocations: 16
        },
        authority_requirements: [%{capability_id: "advance", mode: :required, scope: "meeting"}],
        receipt_obligations: [:construction_receipt, :do_receipt]
      ],
      overrides
    )
  end

  @doc "Absolute path to the real HDDL fixture dir used by the solver tests."
  @spec hddl_fixture_dir() :: String.t()
  def hddl_fixture_dir do
    Path.expand("hddl/freedom_gym_meeting", __DIR__)
  end
end
