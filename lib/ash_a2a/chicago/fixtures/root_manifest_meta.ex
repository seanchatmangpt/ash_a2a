defmodule AshA2A.Chicago.Fixtures.RootManifestMeta do
  @moduledoc """
  Real machinery, real Root Manifests and real nested qualification runs for
  the Meta-Admission (`SA2A-META`, RFC-SA2A-002 §52, §136-§137) and Root
  Manifest (`SA2A-ROOT`, §53) courts.

  Nothing here decides a verdict. Every artifact is real input for the real
  boundary that judges it:

    * pipeline law (ShEx, SHACL, N3 rules, OWL profile) for
      `AshA2A.Semantic.AdmissionPipeline` over the real `praxis-graphlaw` wasm,
      judged under the Gate 2 world's admitted law
      (`AshA2A.Chicago.Fixtures.ShexShaclAdmission.law_manifest!/1`);
    * one admitted and one unadmitted artifact of every other machinery kind,
      run through its real machinery for its APPARENT result -- a Datalog
      program closed by `AshA2A.Semantic.LogicClosure`, a SPARQL falsifier
      executed by SPARQL.ex, a planning domain solved by the real `hddl_cli`,
      a generator template rendered by `:io_lib.format/2`, an authority policy
      resolved by `AshA2A.Authority.Grant.policy/1`, a receipt schema checked
      over a real `AshA2A.Receipt`, a knowledge hook validated by
      `AshA2A.Semantic.HookReactor.Hook.validate/1` -- and then submitted to
      `AshA2A.Semantic.MetaAdmission.confer/5`;
    * semantic mapping admission receipts committed to a real
      `AshA2A.ReceiptStore.Memory` for `AshA2A.Semantic.MappingRegistry`;
    * a staged copy of the committed conformance corpus for Root Manifest
      load / use-time verification;
    * discoverable-false gate courts for nested `AshA2A.Chicago.Runner` runs
      against a court manifest (`AshA2A.Chicago.CourtManifest`).
  """

  alias AshA2A.{Command, Receipt}
  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.Ocel.Mapping
  alias AshA2A.GraphLaw.WasmexSession
  alias AshA2A.Planning.HddlSolver
  alias AshA2A.ReceiptStore.Memory
  alias AshA2A.Semantic.{LogicClosure, MappingRegistry, MetaAdmission, RootManifest}
  alias AshA2A.Semantic.HookReactor.Hook
  alias AshA2A.Semantic.RootManifest.{ConformanceCorpus, LawCorpus}

  @ex "http://example.org/sa2a-world/"
  @sa "http://seanchatmangpt.github.io/sa2a#"
  @meta "http://example.org/sa2a-meta/"

  # --- OCEL mappings (shared: one source, so the runner admits each once) ------

  @doc "OCEL mappings for the meta-admission, root-manifest and court-manifest boundaries."
  @spec mappings() :: [Mapping.t()]
  def mappings do
    [
      Mapping.new!(
        event: MetaAdmission.standing_event(),
        activity: "semantic.meta_admission.standing",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"machinery", meta[:artifact_digest], meta[:kind] || "unknown"},
            {"root_manifest", meta[:manifest_digest], "manifest"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:kind, :outcome, :reason, :consumer]) end
      ),
      Mapping.new!(
        event: MetaAdmission.confer_event(),
        activity: "semantic.meta_admission.confer",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"machinery", meta[:artifact_digest], meta[:kind] || "unknown"},
            {"root_manifest", meta[:manifest_digest], "manifest"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:kind, :outcome, :reason, :consumer]) end
      ),
      Mapping.new!(
        event: RootManifest.verify_event(),
        activity: "semantic.root_manifest.verify",
        source: __MODULE__,
        objects: fn _m, meta -> [{"root_manifest", meta[:manifest_digest], "manifest"}] end,
        attributes: fn _m, meta -> Map.take(meta, [:phase, :outcome, :code, :component]) end
      ),
      Mapping.new!(
        event: RootManifest.mutate_event(),
        activity: "semantic.root_manifest.mutate",
        source: __MODULE__,
        objects: fn _m, meta ->
          [
            {"root_manifest", meta[:manifest_digest], "manifest"},
            {"root_manifest", meta[:new_manifest_digest], "mutated_manifest"}
          ]
        end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :authority_source]) end
      ),
      Mapping.new!(
        event: AshA2A.Chicago.CourtManifest.verified_event(),
        activity: "chicago.court_manifest.verified",
        source: __MODULE__,
        objects: fn _m, meta -> [{"court_manifest", meta[:admitted_digest], "admitted"}] end,
        attributes: fn _m, meta -> Map.take(meta, [:outcome, :drift, :court_ids]) end
      )
    ]
  end

  # --- pipeline machinery (substituted law) ---------------------------------------

  @doc "A non-vacuous ShExJ schema that only asks for `sa:version` -- it admits a label-less world."
  @spec self_serving_shex_schema() :: String.t()
  def self_serving_shex_schema do
    ~s({"type":"Schema","shapes":[{"type":"ShapeDecl","id":"#{@ex}WorldShape","shapeExpr":) <>
      ~s({"type":"Shape","expression":{"type":"TripleConstraint","predicate":"#{@sa}version",) <>
      ~s("valueExpr":{"type":"NodeConstraint","datatype":"http://www.w3.org/2001/XMLSchema#integer"},) <>
      ~s("min":1,"max":1}}}]})
  end

  @doc "A non-vacuous shapes graph that only checks capability tiers."
  @spec self_serving_shacl_shapes() :: String.t()
  def self_serving_shacl_shapes do
    """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix sa: <#{@sa}> .
    @prefix ex: <#{@ex}> .

    ex:TierOnlyShape a sh:NodeShape ;
      sh:targetClass sa:Capability ;
      sh:property [ sh:path sa:tier ; sh:minCount 1 ] .
    """
  end

  @doc "The world's falsifier set plus a rule deriving the missing authority requirement."
  @spec laundering_rules() :: String.t()
  def laundering_rules do
    AshA2A.Chicago.Fixtures.ShexShaclAdmission.falsifiers() <>
      "@prefix sa: <#{@sa}> .\n" <>
      "{ ?a sa:hasConsequence ?c } => { ?a sa:requiresAuthority sa:DerivedAuthority } .\n"
  end

  @doc "A non-vacuous OWL profile the world never admitted."
  @spec unadmitted_profile() :: String.t()
  def unadmitted_profile do
    """
    @prefix owl: <http://www.w3.org/2002/07/owl#> .
    @prefix sa: <#{@sa}> .
    sa:World a owl:Class .
    """
  end

  # --- production-standing machinery (MetaAdmission.confer/5) --------------------

  @gate_kinds ~w(datalog_program sparql_falsifier planning_domain generator authority_policy receipt_schema hook)

  @doc "Machinery kinds whose production standing is conferred through `MetaAdmission.confer/5`."
  @spec gate_kinds() :: [String.t()]
  def gate_kinds, do: @gate_kinds

  @doc "The admitted (`:admitted`) or substituted (`:rogue`) artifact of `kind`."
  @spec artifact(String.t(), :admitted | :rogue) :: String.t()
  def artifact("datalog_program", :admitted),
    do: "@prefix ex: <#{@meta}> .\n{ ?x ex:parentOf ?y } => { ?y ex:childOf ?x } .\n"

  def artifact("datalog_program", :rogue),
    do: "@prefix ex: <#{@meta}> .\n{ ?x ex:requested ?y } => { ?x ex:administers ?y } .\n"

  def artifact("sparql_falsifier", :admitted), do: "ASK { ?x a <#{@meta}Forbidden> }"
  def artifact("sparql_falsifier", :rogue), do: "ASK { ?x a <#{@meta}NeverAsserted> }"

  def artifact("planning_domain", :admitted), do: domain(true)
  def artifact("planning_domain", :rogue), do: domain(false)

  def artifact("generator", :admitted),
    do: "defmodule ~ts do\n  def standing, do: :candidate\n  def authority, do: :none\nend\n"

  def artifact("generator", :rogue),
    do:
      "defmodule ~ts do\n  def standing, do: :production\n  def authority, do: :root_custodian\nend\n"

  def artifact("authority_policy", :admitted), do: ~s({"authority_policy":"broker"})

  def artifact("authority_policy", :rogue),
    do: ~s({"authority_policy":"transport_verified_grants_capability"})

  def artifact("receipt_schema", :admitted),
    do: JSON.encode!(%{"required_fields" => Enum.map(receipt_fields(), &Atom.to_string/1)})

  def artifact("receipt_schema", :rogue), do: ~s({"required_fields":["recorded_at"]})

  def artifact("hook", :admitted), do: hook_document("meta.hook.admitted", "notify_operator")
  def artifact("hook", :rogue), do: hook_document("meta.hook.rogue", "root_manifest:mutate")

  @doc """
  The artifact's APPARENT result from its real machinery, over the negative
  (`:attack`) or positive (`:lawful`) input. `{:blocked, reason}` when that
  machinery cannot run here.
  """
  @spec apparent(String.t(), String.t(), :attack | :lawful) :: term()
  def apparent("datalog_program", rules, _case) do
    case WasmexSession.available?() do
      :ok ->
        program = %LogicClosure.Program{
          facts:
            "@prefix ex: <#{@meta}> .\nex:alice ex:parentOf ex:bob .\nex:mallory ex:requested ex:root .\n",
          rules: rules
        }

        # The caller admits its own rule document: exactly the self-admission
        # meta-admission exists to deny production standing to.
        LogicClosure.close(program, admitted_rules: LogicClosure.admitted_rule_set([rules]))

      {:error, reason} ->
        {:blocked, "GraphLaw wasmex session unavailable: #{inspect(reason)}"}
    end
  end

  def apparent("sparql_falsifier", query, input) do
    graph =
      case input do
        :attack -> "@prefix ex: <#{@meta}> .\nex:intruder a ex:Forbidden .\n"
        :lawful -> "@prefix ex: <#{@meta}> .\nex:visitor a ex:Guest .\n"
      end

    with {:ok, rdf} <- RDF.Turtle.read_string(graph),
         %SPARQL.Query.Result{results: results} <- SPARQL.execute_query(rdf, query) do
      if results == [], do: {:ok, :graph_clear}, else: {:error, {:falsifier_tripped, results}}
    end
  end

  def apparent("planning_domain", domain, input) do
    problem = if input == :attack, do: problem(), else: permitted_problem()

    if File.exists?(HddlSolver.cli_path()),
      do: HddlSolver.solve(domain, problem),
      else: {:blocked, "hddl_cli not built at #{HddlSolver.cli_path()}"}
  end

  def apparent("generator", template, _input) do
    {:ok,
     IO.iodata_to_binary(:io_lib.format(String.to_charlist(template), [~c"Generated.Artifact"]))}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def apparent("authority_policy", document, _input) do
    with {:ok, %{"authority_policy" => name}} <- JSON.decode(document),
         [mode] <-
           Enum.filter(
             [:broker, :transport_verified_grants_capability],
             &(Atom.to_string(&1) == name)
           ) do
      {:ok, Grant.policy(policy: mode)}
    else
      other -> {:error, {:policy_unresolved, other}}
    end
  end

  def apparent("receipt_schema", document, input) do
    receipt =
      case input do
        # A receipt stripped of its effect identity: every S31 field it lacks
        # is one a forged or replayed receipt would lack.
        :attack -> %{sample_receipt() | idempotency_key: nil, input_digest: nil, actor: nil}
        :lawful -> sample_receipt()
      end

    with {:ok, %{"required_fields" => fields}} <- JSON.decode(document) do
      missing =
        for field <- receipt_fields(),
            Atom.to_string(field) in fields,
            is_nil(Map.fetch!(receipt, field)),
            do: field

      if missing == [], do: {:ok, receipt.receipt_id}, else: {:error, {:missing, missing}}
    end
  end

  def apparent("hook", document, _input) do
    with {:ok, fields} <- JSON.decode(document) do
      hook =
        Hook.new(
          id: fields["id"],
          revision: fields["revision"],
          trigger: fields["trigger"],
          witness: fields["witness"],
          intent: %{capability_id: fields["intent"]["capability_id"], input: %{}},
          provenance: %{
            source: fields["provenance"]["source"],
            author: fields["provenance"]["author"]
          }
        )

      with :ok <- Hook.validate(hook), do: {:ok, Hook.digest(hook)}
    end
  end

  @doc """
  The Root Manifest admitting every `gate_kinds/0` artifact's `:admitted`
  form, or `{:error, refusal}` when it cannot be built here (e.g. the engine
  artifact it pins is not resolvable).
  """
  @spec gate_manifest(Path.t()) :: {:ok, RootManifest.t()} | {:error, map()}
  def gate_manifest(dir) do
    documents = for kind <- @gate_kinds, do: {kind, artifact(kind, :admitted)}
    LawCorpus.build(Path.join(dir, "gate-law"), documents)
  end

  # The S31 fields a lawful receipt produced without a plan or semantic subject carries.
  defp receipt_fields,
    do: Receipt.required_fields() -- [:semantic_subject, :plan_digest, :projection_digest]

  defp sample_receipt do
    command =
      Command.new("AshA2A.Chicago.Fixtures.RootManifestMeta.sample",
        command_id: "meta-receipt-#{System.unique_integer([:positive])}",
        agent_id: "meta-agent",
        principal_id: "meta-principal",
        input: %{sample: true},
        authority:
          AshA2A.Authority.new(
            AshA2A.Identity.principal("meta-principal"),
            "AshA2A.Chicago.Fixtures.RootManifestMeta.sample"
          )
      )

    command
    |> Receipt.pending(AshA2A.Identity.new(:execution, "meta-exec"), :none)
    |> Receipt.finalize({:reply, %{ok: true}})
  end

  defp hook_document(id, capability) do
    JSON.encode!(%{
      "id" => id,
      "revision" => 1,
      "trigger" => "@prefix ex: <#{@meta}> .\n{ ?x a ex:Alert } => false .",
      "witness" => "@prefix ex: <#{@meta}> .\nex:a1 a ex:Alert .",
      "intent" => %{"capability_id" => capability},
      "provenance" => %{"source" => "sa2a-meta court", "author" => "sa2a-meta"}
    })
  end

  # `has-permission` is the precondition the admitted domain enforces; the
  # substituted domain drops it, so the same problem (which grants no
  # permission) is solvable only under the substitute.
  defp domain(enforce_permission?) do
    precondition =
      if enforce_permission?,
        do: "(and (current-phase ?from) (has-permission))",
        else: "(current-phase ?from)"

    """
    (define (domain meta-permission)
      (:types phase)
      (:predicates
        (current-phase ?p - phase)
        (has-permission))
      (:task run-sequence :parameters (?start - phase))
      (:action advance
        :parameters (?from - phase ?to - phase)
        :precondition #{precondition}
        :effect (and (not (current-phase ?from)) (current-phase ?to)))
      (:method m-run-sequence
        :parameters (?start - phase)
        :task (run-sequence ?start)
        :ordered-subtasks (and
          (t1 (advance locked unlocked)))))
    """
  end

  @doc "The planning problem both domains are asked to solve (no permission granted)."
  @spec problem() :: String.t()
  def problem do
    """
    (define (problem meta-permission-p1)
      (:domain meta-permission)
      (:objects locked unlocked - phase)
      (:htn
        :parameters ()
        :ordered-subtasks (and (m1 (run-sequence locked))))
      (:init (current-phase locked))
      (:goal (and (current-phase unlocked))))
    """
  end

  @doc "The admitted domain's problem: the same goal, with permission granted."
  @spec permitted_problem() :: String.t()
  def permitted_problem do
    String.replace(
      problem(),
      "(:init (current-phase locked))",
      "(:init (current-phase locked) (has-permission))"
    )
  end

  # --- semantic mappings -------------------------------------------------------------

  @doc "Two peers whose capability labels collide while their identities differ."
  @spec peers() :: {map(), map(), map()}
  def peers do
    {%{peer_id: "meta-a", label: "berth slot", iri: "#{@meta}peerA/berthSlot"},
     %{peer_id: "meta-b", label: "berth slot", iri: "#{@meta}peerB/berthSlot"},
     %{peer_id: "meta-c", label: "berth slot", iri: "#{@meta}peerC/berthSlot"}}
  end

  @doc """
  A receipt claimed, executed, committed to and fetched back from the real
  store `name`, for the admission of `source -> target` (`:exact_match`).
  """
  @spec admission_receipt(atom(), String.t(), String.t()) :: Receipt.t()
  def admission_receipt(name, source, target) do
    command =
      Command.new("AshA2A.Chicago.Fixtures.RootManifestMeta.admit_mapping",
        command_id: "meta-mapping-#{System.unique_integer([:positive])}",
        agent_id: "meta-agent",
        principal_id: "meta-principal",
        input: MappingRegistry.admission_input(source, target, :exact_match)
      )

    {:execute, execution_id} = Memory.claim(command, name: name)

    receipt =
      command
      |> Receipt.pending(execution_id, :none)
      |> Receipt.finalize({:reply, %{admitted: true}})

    :ok = Memory.commit(receipt, name: name)
    {:ok, held} = Memory.fetch(command.command_id, name: name)
    held
  end

  @doc "Runs `fun.(store_name)` with a real, freshly started `AshA2A.ReceiptStore.Memory`."
  @spec with_store((atom() -> result)) :: result when result: var
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    {:ok, pid} = Memory.start_link(name: name)

    try do
      fun.(name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # --- Root Manifest staging --------------------------------------------------------

  @doc """
  Copies the committed conformance corpus to `dir/conformance`, builds its
  manifest there with the committed spec, and writes `dir/root_manifest.json`.
  Returns `%{root:, path:, manifest:}`.
  """
  @spec stage_corpus!(Path.t()) :: %{root: Path.t(), path: Path.t(), manifest: RootManifest.t()}
  def stage_corpus!(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(ConformanceCorpus.root(), "conformance"), Path.join(dir, "conformance"))
    {:ok, manifest} = ConformanceCorpus.build(root: dir)
    path = Path.join(dir, "root_manifest.json")
    RootManifest.write!(manifest, path)
    %{root: dir, path: path, manifest: manifest}
  end

  @doc """
  A self-consistent manifest: `changes` applied to `manifest` and the content
  address recomputed -- an out-of-band edit that also re-addressed the
  document, bypassing `RootManifest.mutate/5` custody.
  """
  @spec readdressed(RootManifest.t(), map()) :: RootManifest.t()
  def readdressed(%RootManifest{} = manifest, changes) do
    edited = struct!(manifest, changes)
    %{edited | digest: RootManifest.content_digest(edited)}
  end

  @doc "sha256 hex of a file's bytes (independent reader; `nil` when absent)."
  @spec file_sha256(Path.t()) :: String.t() | nil
  def file_sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  @doc "Copies `source` to `dest` with its last byte flipped."
  @spec flipped_copy!(Path.t(), Path.t()) :: Path.t()
  def flipped_copy!(source, dest) do
    bytes = File.read!(source)
    size = byte_size(bytes) - 1
    <<head::binary-size(size), last>> = bytes
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, <<head::binary, Bitwise.bxor(last, 0xFF)>>)
    dest
  end

  # --- nested court runs ----------------------------------------------------------------

  @doc "The three gate fixture courts whose clean nested run can be CONFORMANT for `:core`."
  @spec gate_courts() :: [module()]
  def gate_courts,
    do: [__MODULE__.GateCourt1, __MODULE__.GateCourt2, __MODULE__.GateCourt3]

  @doc """
  One nested `AshA2A.Chicago.Runner` run of `courts` under `:core` against
  `court_manifest` (a document), written to `dir/court_manifest.json`.
  """
  @spec nested_run(Path.t(), [module()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def nested_run(dir, courts, court_manifest, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "court_manifest.json")
    AshA2A.Chicago.CourtManifest.write!(court_manifest, path)

    AshA2A.Chicago.Runner.run(
      [
        courts: courts,
        profile: :core,
        evidence_dir: Path.join(dir, "package"),
        court_manifest: path
      ] ++
        opts
    )
  end

  @doc false
  def gate_falsifier(court_id, invariant) do
    AshA2A.Chicago.Falsifier.new!(
      id: court_id <> "-001",
      court_id: court_id,
      kind: :positive_control,
      invariant: invariant,
      stimulus:
        "MetaAdmission.document_standing/4 of the committed command-envelope SHACL shapes",
      boundary: "AshA2A.Semantic.MetaAdmission.document_standing/4",
      attempt_evidence: "semantic.meta_admission.standing kind=shacl_shapes",
      survival_evidence: "semantic.meta_admission.standing outcome=admitted",
      attempt_predicate:
        {:observed, "semantic.meta_admission.standing", %{"kind" => "shacl_shapes"}},
      outcome_predicate:
        {:observed, "semantic.meta_admission.standing",
         %{"kind" => "shacl_shapes", "outcome" => "admitted"}}
    )
  end

  @doc false
  def gate_run(ctx, [falsifier]) do
    alias AshA2A.Chicago.{Context, Result}

    {:ok, manifest} = RootManifest.load(nil, require_engine: false)
    path = "conformance/shapes/command_envelope.shacl.ttl"
    shapes = File.read!(RootManifest.resolve(manifest, path))

    reply =
      Context.stimulus(ctx, falsifier, fn ->
        MetaAdmission.document_standing(manifest, shapes, "shacl_shapes")
      end)

    [
      Result.positive(falsifier,
        attempt_observed?: Context.observed?(ctx, falsifier, "semantic.meta_admission.standing"),
        expected_outcome_observed?: match?({:ok, %{"path" => ^path}}, reply),
        evidence: %{"reply" => inspect(reply, limit: 5)}
      )
    ]
  end
end

for {gate, suffix, invariant} <- [
      {1, "1", "Committed machinery has standing (gate 1 fixture)"},
      {2, "2", "Committed machinery has standing (gate 2 fixture)"},
      {3, "3", "Committed machinery has standing (gate 3 fixture)"},
      {1, "1Drifted",
       "Committed machinery has standing (gate 1 fixture, declaration revised after admission)"}
    ] do
  defmodule Module.concat(AshA2A.Chicago.Fixtures.RootManifestMeta, "GateCourt" <> suffix) do
    @moduledoc """
    Discoverable-false gate fixture court for nested court-meta-admission runs
    (RFC-SA2A-002 §137). `GateCourt1Drifted` has `GateCourt1`'s id with a
    revised falsifier declaration: court machinery that drifted after its
    manifest was admitted.
    """

    use AshA2A.Chicago.Court, discoverable: false

    alias AshA2A.Chicago.Fixtures.RootManifestMeta, as: F

    @gate gate
    @court_id "SA2A-METAFIX-G#{gate}"
    @invariant invariant

    @impl true
    def id, do: @court_id
    @impl true
    def title, do: "Court meta-admission fixture: gate #{@gate}"
    @impl true
    def gate, do: @gate
    @impl true
    def profile, do: :core
    @impl true
    def rfc_sections, do: ["§137"]
    @impl true
    def ocel_mappings, do: F.mappings()
    @impl true
    def falsifiers, do: [F.gate_falsifier(@court_id, @invariant)]
    @impl true
    def run(ctx), do: F.gate_run(ctx, falsifiers())
  end
end

defmodule AshA2A.Chicago.Fixtures.RootManifestMeta.SubstituteOcelValidator do
  @moduledoc """
  An OCEL validator substituted for the admitted one: it delegates validation
  to `AshA2A.Chicago.Ocel.Validator` (so the evidence still validates) but is
  a different module with a different declared identity -- court machinery
  the admitted court manifest never admitted (RFC-SA2A-002 §137).
  """

  @doc "Declared identity (differs from the admitted validator's)."
  def identity do
    %{"name" => "substitute-ocel-validator", "version" => "0.0.1", "specification" => "none"}
  end

  @doc "Delegates to the real independent validator."
  def validate_file(path), do: AshA2A.Chicago.Ocel.Validator.validate_file(path)
end
