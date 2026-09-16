defmodule AshA2A.Chicago.Fixtures.UnknownLlm.Gate do
  @moduledoc """
  Real Ash resource for the Gate 12 / UNKNOWN / LLM / machine-experience
  courts (RFC-SA2A-002 §43, §79-§82, §134).

  Two real generic actions each declare one real `hddl_operator`, forming a
  two-step STRIPS domain the real `native/hddl_cli` solver verifies:

    * `:advance` -- `current_phase(?from)` -> `current_phase(?to)`
    * `:unlock` -- once `current_phase(?who)` holds, asserts `has_key(?who)`

  `semantic_requests true` opts the resource into the production semantic
  A2A surface (`AshA2A.Agent.__dispatch__/3`), so the KNOWN reflex is also
  exercised through the real generated-agent call site.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.UnknownLlm.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :advance, :string do
      argument(:from, :string, allow_nil?: false)
      argument(:to, :string, allow_nil?: false)
      run(fn _input, _context -> {:ok, "advanced"} end)
    end

    action :unlock, :string do
      argument(:who, :string, allow_nil?: false)
      run(fn _input, _context -> {:ok, "unlocked"} end)
    end
  end

  a2a do
    semantic_requests(true)

    skill :advance, :advance do
      consequence(:observe)

      hddl_operator do
        parameters([:from, :to])
        preconditions([{:current_phase, [:from]}])
        add_effects([{:current_phase, [:to]}])
        delete_effects([{:current_phase, [:from]}])
      end
    end

    skill :unlock, :unlock do
      consequence(:observe)

      hddl_operator do
        parameters([:who])
        preconditions([{:current_phase, [:who]}])
        add_effects([{:has_key, [:who]}])
      end
    end
  end
end

defmodule AshA2A.Chicago.Fixtures.UnknownLlm.Ledger do
  @moduledoc """
  Real `:change`-consequence Ash resource: the DO an UNKNOWN subject, a
  discovery candidate or a model-generated authority claim must never reach.
  Post-state is read back through `Ash.read!/1`, an independent reader.
  """

  use Ash.Resource,
    domain: AshA2A.Chicago.Fixtures.UnknownLlm.Domain,
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
    skill(:create, :create)
  end
end

defmodule AshA2A.Chicago.Fixtures.UnknownLlm.Domain do
  @moduledoc "Fixture domain for the UNKNOWN/LLM courts; never registered in config."

  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.Chicago.Fixtures.UnknownLlm.Gate)
    resource(AshA2A.Chicago.Fixtures.UnknownLlm.Ledger)
  end
end

defmodule AshA2A.Chicago.Fixtures.UnknownLlm do
  @moduledoc """
  Stimulus material for `CHI-KNOWN`, `SA2A-UNKNOWN`, `SA2A-LLM` and `SA2A-MX`.

  ## Why the model is a deterministic function, not a live model

  The components under qualification are the boundaries that receive model
  output -- `AshA2A.Semantic.Compiler`, `AshA2A.Planning.SemanticSynthesis`,
  `AshA2A.Semantic.LlmBoundary`, `AshA2A.Semantic.Unknown`,
  `AshA2A.Semantic.Admission` -- never the model. A live model is a paid,
  networked, nondeterministic external service, and the courts must run
  offline (RFC-SA2A-002 §10 permits changing the environment around a real
  component). `model/1` is a real 4-arity function plugged into the SUT's own
  documented `:generate_object` seam that returns one fixed model-shaped
  output; every boundary downstream of it executes for real. Whether the
  model was *invoked* is never inferred from this function: it is read from
  the SUT's own `[:ash_a2a, :llm, :invoke]` telemetry.
  """

  alias AshA2A.{Authority, Command, Identity}
  alias AshA2A.Chicago.Fixtures.UnknownLlm.{Gate, Ledger}
  alias AshA2A.Semantic.RootManifest
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @advance "AshA2A.Chicago.Fixtures.UnknownLlm.Gate.advance"
  @unlock "AshA2A.Chicago.Fixtures.UnknownLlm.Gate.unlock"
  @record "AshA2A.Chicago.Fixtures.UnknownLlm.Ledger.create"

  @known_phrase "advance the gate from on to off and unlock it"
  @gate_phrase ~r/^advance the gate from (?<from>[a-z]+) to (?<to>[a-z]+) and unlock it$/

  @doc "The HDDL-operator resource."
  def gate, do: Gate
  @doc "The `:change` resource."
  def ledger, do: Ledger
  @doc "Canonical capability ids of the gate reflex."
  def gate_capabilities, do: [@advance, @unlock]
  @doc "Canonical capability id of the ledger DO."
  def record_capability, do: @record

  @doc "A typed-facts envelope the real solver confirms (on -> off, key held)."
  @spec goal_facts(String.t(), String.t(), String.t()) :: map()
  def goal_facts(request_id, from \\ "on", to \\ "off") do
    %{
      "request_id" => request_id,
      "domain_name" => "chicago-gate-domain",
      "problem_name" => "chicago-gate-problem",
      "objects" => Enum.uniq([from, to]),
      "init" => [%{"predicate" => "current_phase", "args" => [from]}],
      "goal" => [
        %{"predicate" => "current_phase", "args" => [to]},
        %{"predicate" => "has_key", "args" => [to]}
      ],
      "task_sequence" => [
        %{"capability_id" => @advance, "args" => [from, to]},
        %{"capability_id" => @unlock, "args" => [to]}
      ]
    }
  end

  @doc "A2A message carrying a typed goal-facts Data part."
  def facts_message(envelope, metadata \\ nil) do
    message = A2A.Message.new_user([A2A.Part.Data.new(%{"goal_facts" => envelope})])
    if metadata, do: %{message | metadata: metadata}, else: message
  end

  @doc "A2A message carrying free text only."
  def text_message(text), do: A2A.Message.new_user(text)

  @doc "The KNOWN phrase compiled into `gate_phrase_template/0`."
  def known_phrase, do: @known_phrase

  @doc "The admitted phrase template (compiled machinery) for the gate class."
  def gate_phrase_template do
    %{
      regex: @gate_phrase,
      to_envelope: fn %{"from" => from, "to" => to} ->
        goal_facts("chicago-phrase-#{unique()}", from, to)
      end
    }
  end

  @doc "Deterministic stand-in model: always returns `output` (see moduledoc)."
  def model(output), do: fn _model_spec, _prompt, _schema, _opts -> {:ok, output} end

  @doc """
  Model seam that must never be reached on a KNOWN route. It fails instead
  of answering so a regression cannot silently succeed; invocation itself is
  observed through the SUT's `llm.invoke` telemetry.
  """
  def tripwire_model do
    fn _model_spec, _prompt, _schema, _opts ->
      {:error, %{reason: "chicago tripwire: model inference allocated on a KNOWN route"}}
    end
  end

  @doc "Semantic IR proposal a model would emit, grounded in `text` unless overridden."
  def ir_proposal(text, overrides \\ %{}) do
    AshA2A.Semantic.IR.fields()
    |> Map.new(&{Atom.to_string(&1), []})
    |> Map.put("authority", "none")
    |> Map.put("goals", [
      %{"id" => "goal-1", "kind" => "goal", "description" => text, "source_quote" => text}
    ])
    |> Map.merge(overrides)
  end

  @doc "Plan proposal a model would emit to `SemanticSynthesis`."
  def plan_proposal(capability_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "chicago-model-plan-#{unique()}",
        "authority" => "none",
        "capability_ids" => capability_ids,
        "hddl" => "(:htn :ordered-subtasks (advance on off) (unlock off))",
        "fond" => "policy: advance then unlock",
        "rationale" => "model-proposed candidate"
      },
      overrides
    )
  end

  @doc "A real principal identity for DO attempts."
  def principal, do: Identity.principal("chicago-unknown-llm-subject")

  @doc "A ledger DO command; `authority` is an `%Authority{}` or nil."
  def ledger_command(label, authority) do
    Command.new(@record,
      command_id: "chicago-ul-" <> label,
      agent_id: "chicago-unknown-llm-agent",
      principal_id: principal(),
      authority: authority,
      input: %{label: label}
    )
  end

  @doc "An authority of `source` for the ledger DO, bound to `principal/0`."
  def ledger_authority(source, evidence \\ %{}) do
    Authority.new(principal(), @record,
      token_id: "chicago-ul-#{source}-#{unique()}",
      source: source,
      evidence: evidence
    )
  end

  @doc "The Data-part message for a ledger DO."
  def ledger_message(label), do: A2A.Message.new_user([A2A.Part.Data.new(%{"label" => label})])

  @doc "Labels currently persisted, read through an independent `Ash.read!/1`."
  def ledger_labels, do: Ledger |> Ash.read!() |> Enum.map(& &1.label)

  @doc "Runs `fun` with a fresh real `AshA2A.ReceiptStore.Memory`."
  def with_store(fun) do
    name = Module.concat(__MODULE__, "Store#{unique()}")
    {:ok, pid} = AshA2A.ReceiptStore.Memory.start_link(name: name)

    try do
      fun.(name: name)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @doc """
  Stages a writable copy of the real SA2A conformance corpus under `dir` and
  builds a real `RootManifest` over it (real SHA-256 pins, real engine pin).
  """
  @spec stage_corpus(Path.t()) :: {:ok, RootManifest.t()} | {:error, term()}
  def stage_corpus(dir) do
    root = Path.join(dir, "sa2a-corpus-#{unique()}")
    File.mkdir_p!(root)
    File.cp_r!(Path.join(ConformanceCorpus.root(), "conformance"), Path.join(root, "conformance"))
    RootManifest.build(root, ConformanceCorpus.spec())
  end

  @doc "Unique positive integer."
  def unique, do: System.unique_integer([:positive])
end
