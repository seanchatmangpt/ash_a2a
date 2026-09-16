defmodule AshA2A.Chicago.Courts.InferenceMappings do
  @moduledoc """
  Admitted OCEL mappings (RFC-SA2A-002 §17) for the inference, planning,
  UNKNOWN, allocation and candidate-standing boundaries qualified by
  `CHI-KNOWN`, `SA2A-UNKNOWN`, `SA2A-LLM` and `SA2A-MX`.

  Not a court. Every court declares the subset it relies on from this one
  module, so the same telemetry event always maps to the same activity with
  the same object relations whichever courts share a run. Predicates in those
  courts only ask presence/absence/precedence questions, so a run whose
  mapping set carries a copy per court stays decidable.

  | telemetry event | activity |
  |---|---|
  | `[:ash_a2a, :llm, :invoke]` | `llm.invoke` |
  | `[:ash_a2a, :planner, :invoke]` | `planner.invoke` |
  | `[:ash_a2a, :router, :tier_refused]` | `router.tier_refused` |
  | `[:ash_a2a, :semantic, :allocation]` | `semantic.allocation` |
  | `[:ash_a2a, :semantic, :unknown, :admit_for_do]` | `unknown.admit_for_do` |
  | `[:ash_a2a, :semantic, :llm_boundary, :candidate]` | `llm_boundary.candidate` |
  | `[:ash_a2a, :semantic, :allocator, :decision]` | `allocator.decision` |
  | `[:ash_a2a, :semantic, :machine_experience, :compile_back]` | `machine_experience.compile_back` |
  | `[:ash_a2a, :semantic, :machine_experience, :register]` | `machine_experience.register` |
  | `[:ash_a2a, :semantic, :ir_admission]` | `semantic.ir_admission` |
  | `[:ash_a2a, :semantic, :meta_admission, :standing]` | `meta_admission.standing` |
  | `[:ash_a2a, :semantic, :root_manifest, :mutate]` | `root_manifest.mutate` |
  """

  alias AshA2A.Chicago.Ocel.Mapping

  @spec llm_invoke() :: Mapping.t()
  def llm_invoke do
    Mapping.new!(
      event: [:ash_a2a, :llm, :invoke],
      activity: "llm.invoke",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"inference_site", meta[:site], "site"},
          {"semantic_source", meta[:source_id], "source"},
          {"resource", resource(meta), "resource"}
        ]
      end,
      attributes: fn _m, meta -> Map.take(meta, [:site, :role]) end
    )
  end

  @spec planner_invoke() :: Mapping.t()
  def planner_invoke do
    Mapping.new!(
      event: [:ash_a2a, :planner, :invoke],
      activity: "planner.invoke",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"planner", meta[:planner], "planner"},
          {"plan_candidate", meta[:fingerprint], "candidate"},
          {"resource", resource(meta), "resource"}
        ]
      end,
      attributes: fn _m, meta ->
        Map.take(meta, [:planner, :outcome, :code, :standing, :authority])
      end
    )
  end

  @spec router_tier_refused() :: Mapping.t()
  def router_tier_refused do
    Mapping.new!(
      event: [:ash_a2a, :router, :tier_refused],
      activity: "router.tier_refused",
      source: __MODULE__,
      objects: fn _m, meta -> [{"resource", resource(meta), "resource"}] end,
      attributes: fn _m, meta -> Map.take(meta, [:code]) end
    )
  end

  @spec allocation() :: Mapping.t()
  def allocation do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :allocation],
      activity: "semantic.allocation",
      source: __MODULE__,
      objects: fn _m, meta -> [{"semantic_class", meta[:class], "class"}] end,
      attributes: fn _m, meta -> Map.take(meta, [:resolver]) end
    )
  end

  @spec unknown_admit_for_do() :: Mapping.t()
  def unknown_admit_for_do do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :unknown, :admit_for_do],
      activity: "unknown.admit_for_do",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"semantic_class", meta[:class], "class"},
          {"unknown", meta[:fingerprint], "subject"}
        ]
      end,
      attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :reason]) end
    )
  end

  @spec llm_boundary_candidate() :: Mapping.t()
  def llm_boundary_candidate do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :llm_boundary, :candidate],
      activity: "llm_boundary.candidate",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"semantic_class", meta[:class], "class"},
          {"resolution", meta[:fingerprint], "candidate"}
        ]
      end,
      attributes: fn _m, meta ->
        Map.take(meta, [:outcome, :code, :effect, :key, :standing, :authority, :resolver])
      end
    )
  end

  @spec allocator_decision() :: Mapping.t()
  def allocator_decision do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :allocator, :decision],
      activity: "allocator.decision",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"budget", meta[:budget], "budget"},
          {"budget", meta[:next_budget], "issued"}
        ]
      end,
      attributes: fn _m, meta ->
        Map.take(meta, [
          :op,
          :outcome,
          :code,
          :dimension,
          :requested,
          :charged,
          :limit,
          :consumed,
          :issuer
        ])
      end
    )
  end

  @spec compile_back() :: Mapping.t()
  def compile_back do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :machine_experience, :compile_back],
      activity: "machine_experience.compile_back",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"semantic_class", meta[:class], "class"},
          {"machinery", meta[:fingerprint], "machinery"}
        ]
      end,
      attributes: fn _m, meta ->
        Map.take(meta, [:outcome, :code, :kind, :resolver, :standing, :authority])
      end
    )
  end

  @spec register() :: Mapping.t()
  def register do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :machine_experience, :register],
      activity: "machine_experience.register",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"semantic_class", meta[:class], "class"},
          {"machinery", meta[:fingerprint], "machinery"}
        ]
      end,
      attributes: fn _m, meta -> Map.take(meta, [:kind, :added]) end
    )
  end

  @spec ir_admission() :: Mapping.t()
  def ir_admission do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :ir_admission],
      activity: "semantic.ir_admission",
      source: __MODULE__,
      objects: fn _m, meta -> [{"semantic_source", meta[:source_id], "source"}] end,
      attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :standing, :authority]) end
    )
  end

  @spec meta_admission_standing() :: Mapping.t()
  def meta_admission_standing do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :meta_admission, :standing],
      activity: "meta_admission.standing",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"semantic_artifact", meta[:artifact], "artifact"},
          {"root_manifest", meta[:manifest_digest], "manifest"}
        ]
      end,
      attributes: fn _m, meta -> Map.take(meta, [:outcome, :reason, :kind]) end
    )
  end

  @spec root_manifest_mutate() :: Mapping.t()
  def root_manifest_mutate do
    Mapping.new!(
      event: [:ash_a2a, :semantic, :root_manifest, :mutate],
      activity: "root_manifest.mutate",
      source: __MODULE__,
      objects: fn _m, meta ->
        [
          {"root_manifest", meta[:manifest_digest], "manifest"},
          {"root_manifest", meta[:next_digest], "proposed"}
        ]
      end,
      attributes: fn _m, meta -> Map.take(meta, [:outcome, :code, :authority_source]) end
    )
  end

  defp resource(meta), do: meta[:resource_or_domain] && inspect(meta[:resource_or_domain])

  @doc """
  In-run view (never the standing verdict): true when the observer attributed
  at least one `activity` record to `falsifier` whose attributes equal every
  pair in `attrs` (string compare, like `AshA2A.Chicago.Query`).
  """
  @spec seen?(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t(), String.t(), map()) ::
          boolean()
  def seen?(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.any?(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} ->
          to_string(Map.get(record.attributes, to_string(k))) == to_string(v)
        end)
    end)
  end

  @doc "Distinct attributed `activity` records (by sequence) matching `attrs`."
  @spec count(AshA2A.Chicago.Context.t(), AshA2A.Chicago.Falsifier.t(), String.t(), map()) ::
          non_neg_integer()
  def count(ctx, falsifier, activity, attrs \\ %{}) do
    ctx
    |> AshA2A.Chicago.Context.observed(falsifier)
    |> Enum.filter(fn record ->
      record.activity == activity and
        Enum.all?(attrs, fn {k, v} ->
          to_string(Map.get(record.attributes, to_string(k))) == to_string(v)
        end)
    end)
    |> Enum.uniq_by(& &1.seq)
    |> length()
  end

  @doc "Runs `fun`, converting a raise/throw/exit into `{:raised, message}` (still evidence)."
  @spec guarded((-> term())) :: term()
  def guarded(fun) do
    fun.()
  rescue
    exception -> {:raised, Exception.message(exception)}
  catch
    kind, reason -> {:raised, "#{kind}: #{inspect(reason, limit: 5)}"}
  end
end
