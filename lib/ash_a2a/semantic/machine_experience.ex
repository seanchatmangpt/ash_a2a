defmodule AshA2A.Semantic.MachineExperience.Machinery do
  @moduledoc """
  One piece of reusable machinery compiled back from a resolved UNKNOWN
  (RFC S39/S65): a rule, a shape, a plan, or a generator, keyed by the
  semantic class it closes.

  `apply_fun` is a real deterministic 1-arity function over the subject.
  It is deliberately excluded from `fingerprint` (a closure's binary
  representation is not stable across recompiles); the fingerprint
  covers `{class, kind, provenance}`, which is the content a changelog
  or receipt cares about.

  `provenance` records which resolution this machinery came from --
  resolver kind and resolution fingerprint -- so "this deterministic
  path exists because an LLM once resolved class X" stays auditable
  instead of becoming anonymous machinery.
  """

  @enforce_keys [:class, :kind, :apply_fun, :provenance, :fingerprint]
  defstruct [:class, :kind, :apply_fun, :provenance, :fingerprint]

  @type kind :: :rule | :shape | :plan | :generator

  @type t :: %__MODULE__{
          class: String.t(),
          kind: kind(),
          apply_fun: (term() -> {:ok, term()} | :no_match),
          provenance: map(),
          fingerprint: String.t()
        }
end

defmodule AshA2A.Semantic.MachineExperience.Store do
  @moduledoc """
  A real, immutable, caller-threaded registry of compiled-back machinery,
  keyed by semantic class.

  Threaded rather than global on purpose: the whole point of RFC S65 is
  that the *closed set* of deterministic machinery changes over time and
  every change is auditable. A process-global mutable registry would make
  "what machinery existed at time t" unanswerable; a threaded value makes
  it trivially answerable (you hold both stores) and makes concurrent
  tests genuinely independent without any shared-state coordination.
  """

  defstruct entries: %{}

  @type t :: %__MODULE__{
          entries: %{optional(String.t()) => AshA2A.Semantic.MachineExperience.Machinery.t()}
        }
end

defmodule AshA2A.Semantic.MachineExperience do
  @moduledoc """
  RFC S39/S65: a successfully resolved UNKNOWN compiles back into
  reusable machinery, so the same semantic class routes deterministically
  next time.

  This is the seam that makes the system's LLM spend *decline* on a
  recurring semantic class rather than recur forever:

      Allocation_LLM(class, t+1) <= Allocation_LLM(class, t)

  That inequality is **measured**, not asserted. `AshA2A.Semantic.Unknown.route/3`
  emits `[:ash_a2a, :semantic, :allocation]` with the resolver that was
  actually spent (`:machinery` for a deterministic hit, `:llm`/`:human`/
  ... for a resolver call), and `AshA2A.Telemetry.AllocationCounters`
  accumulates those per class. Before compile-back, routing class X
  spends `:llm`; after, it spends `:machinery`, and the counter shows the
  LLM slot for that class flat. See
  `test/ash_a2a/semantic/machine_experience_test.exs` for the real
  executed measurement.

  ## Compile-back is caller-gated, deliberately

  `compile_back/4` takes a `%Resolution{}` *and the deterministic
  function the caller derived from it*. It does not synthesize machinery
  out of the model payload on its own. A resolution that installed itself
  as machinery would be exactly RFC S40's fifth prohibited effect (a
  model promoting its own rule); requiring the caller to supply the
  deterministic function keeps the promotion decision outside the model.

  ## Registration is changelogged

  `register/2` returns a real `AshA2A.CapabilityIndex.Changelog` entry
  diffing the class set before and after -- reusing the existing
  changelog module rather than inventing a second audit format, so a
  growth of the deterministic set is recorded the same way a change to
  the closed capability set already is.
  """

  alias AshA2A.CapabilityIndex.Changelog
  alias AshA2A.Semantic.MachineExperience.{Machinery, Store}
  alias AshA2A.Semantic.PlanningIR
  alias AshA2A.Semantic.Unknown
  alias AshA2A.Semantic.Unknown.Resolution

  @kinds ~w(rule shape plan generator)a

  @doc "The four machinery kinds RFC S39 names."
  @spec kinds() :: [Machinery.kind()]
  def kinds, do: @kinds

  @doc "A fresh, empty store: no machinery, so every class is genuinely UNKNOWN."
  @spec new_store() :: Store.t()
  def new_store, do: %Store{}

  @doc """
  Compiles a candidate resolution back into reusable machinery.

  Refuses (`:compile_back_requires_candidate`) anything whose standing is
  not `:candidate` with authority `:none` -- the only thing that can be
  compiled back is something that already came through
  `AshA2A.Semantic.LlmBoundary`.
  """
  @spec compile_back(
          Resolution.t(),
          Machinery.kind(),
          (term() -> {:ok, term()} | :no_match),
          keyword()
        ) ::
          {:ok, Machinery.t()} | {:error, map()}
  def compile_back(resolution, kind, apply_fun, opts \\ []) do
    resolution
    |> do_compile_back(kind, apply_fun, opts)
    |> emit_compile_back(resolution, kind)
  end

  defp do_compile_back(
         %Resolution{standing: :candidate, authority: :none} = resolution,
         kind,
         apply_fun,
         opts
       )
       when kind in @kinds and is_function(apply_fun, 1) do
    provenance = %{
      "resolution_fingerprint" => resolution.fingerprint,
      "unknown_fingerprint" => resolution.unknown_fingerprint,
      "resolver" => to_string(resolution.resolver),
      "note" => Keyword.get(opts, :note)
    }

    machinery = %Machinery{
      class: resolution.class,
      kind: kind,
      apply_fun: apply_fun,
      provenance: provenance,
      fingerprint: Unknown.fingerprint({resolution.class, kind, provenance})
    }

    {:ok, machinery}
  end

  defp do_compile_back(%Resolution{} = resolution, kind, apply_fun, _opts) do
    cond do
      kind not in @kinds ->
        {:error, %{code: :unknown_machinery_kind, kind: kind}}

      not is_function(apply_fun, 1) ->
        {:error, %{code: :machinery_requires_deterministic_function}}

      true ->
        {:error,
         %{
           code: :compile_back_requires_candidate,
           standing: resolution.standing,
           authority: resolution.authority
         }}
    end
  end

  defp do_compile_back(other, _kind, _apply_fun, _opts) do
    {:error, %{code: :compile_back_requires_resolution, got: other}}
  end

  # `[:ash_a2a, :semantic, :machine_experience, :compile_back]`: the decision
  # to turn (or refuse to turn) a resolution into reusable machinery
  # (RFC-SA2A-002 §81/§82 evidence). Observational only.
  defp emit_compile_back(result, resolution, kind) do
    source =
      case resolution do
        %Resolution{} = r ->
          %{class: r.class, resolver: r.resolver, standing: r.standing, authority: r.authority}

        _other ->
          %{}
      end

    outcome =
      case result do
        {:ok, %Machinery{} = machinery} ->
          %{outcome: :compiled, fingerprint: machinery.fingerprint}

        {:error, reason} ->
          %{outcome: :refused, code: Map.get(reason, :code)}
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :machine_experience, :compile_back],
      %{count: 1},
      source |> Map.merge(outcome) |> Map.put(:kind, kind)
    )

    result
  end

  @doc """
  Registers machinery into a store, returning the next store and a real
  `AshA2A.CapabilityIndex.Changelog` entry over the class set.

  Re-registering the same class replaces its machinery and produces a
  changelog with an empty `added` (the class was already present) -- a
  replacement is a real change to *what* the machinery is, which the
  machinery fingerprint records, but not to *which* classes route
  deterministically.
  """
  @spec register(Store.t(), Machinery.t()) :: {:ok, Store.t(), Changelog.t()}
  def register(%Store{} = store, %Machinery{} = machinery) do
    before_classes = classes(store)
    next = %{store | entries: Map.put(store.entries, machinery.class, machinery)}

    # `[:ash_a2a, :semantic, :machine_experience, :register]`: the closed
    # deterministic set grew (or was replaced) for `class`. Observational.
    :telemetry.execute(
      [:ash_a2a, :semantic, :machine_experience, :register],
      %{classes: length(classes(next))},
      %{
        class: machinery.class,
        kind: machinery.kind,
        fingerprint: machinery.fingerprint,
        added: machinery.class not in before_classes
      }
    )

    {:ok, next, Changelog.build(before_classes, classes(next))}
  end

  @doc """
  Step 1 of the RFC S64 algorithm: try the admitted deterministic
  machinery for `class`.

  Returns `{:ok, result}` when machinery exists for the class and its
  real function matches this subject, `:no_machinery` otherwise (no
  machinery registered, or registered machinery that does not cover this
  particular subject -- both mean "the admitted machinery is
  insufficient", which is exactly UNKNOWN).

  A raising `apply_fun` is caught and treated as `:no_machinery` rather
  than crashing the router: a buggy compiled-back rule must degrade into
  "still UNKNOWN, resolve it again", never into an exception that
  bypasses the UNKNOWN state entirely.
  """
  @spec resolve(Store.t(), String.t(), term()) :: {:ok, term()} | :no_machinery
  def resolve(%Store{} = store, class, subject) when is_binary(class) do
    case Map.fetch(store.entries, class) do
      {:ok, %Machinery{apply_fun: apply_fun}} -> safe_apply(apply_fun, subject)
      :error -> :no_machinery
    end
  end

  @doc """
  Projects machinery into a real planning observation map -- the same
  `"kind"`-tagged shape `AshA2A.Semantic.Feedback.from_receipt/2` already
  produces for runtime receipts, so the two kinds of evidence land in one
  observation stream rather than two parallel formats.

  Carries no standing and no authority: it is an observation that a class
  now routes deterministically, not a claim about the plan's correctness.
  """
  @spec observation(Machinery.t()) :: map()
  def observation(%Machinery{} = machinery) do
    %{
      "kind" => "compiled_back_machinery",
      "class" => machinery.class,
      "machinery_kind" => to_string(machinery.kind),
      "machinery_fingerprint" => machinery.fingerprint,
      "resolver" => machinery.provenance["resolver"],
      "resolution_fingerprint" => machinery.provenance["resolution_fingerprint"]
    }
  end

  @doc """
  Records a compile-back into a real `AshA2A.Semantic.PlanningIR` via its
  own existing `with_observation/2` -- the codebase's established
  evidence-feedback seam (`Receipt -> observation -> PlanningIR ->
  re-synthesis with a `parent_fingerprint`), reused rather than
  paralleled.

  Returns the next planning IR. Its `fingerprint` genuinely changes,
  because `with_observation/2` recomputes it over the new observation
  list -- so "this plan was re-derived after class X became
  deterministic" is a content-addressed, checkable fact rather than a
  narrative one.
  """
  @spec record_in_planning_ir(PlanningIR.t(), Machinery.t()) :: PlanningIR.t()
  def record_in_planning_ir(%PlanningIR{} = planning, %Machinery{} = machinery) do
    PlanningIR.with_observation(planning, observation(machinery))
  end

  @doc "The sorted class set this store routes deterministically."
  @spec classes(Store.t()) :: [String.t()]
  def classes(%Store{entries: entries}), do: entries |> Map.keys() |> Enum.sort()

  @doc "The machinery registered for `class`, if any."
  @spec fetch(Store.t(), String.t()) :: {:ok, Machinery.t()} | :error
  def fetch(%Store{entries: entries}, class), do: Map.fetch(entries, class)

  defp safe_apply(apply_fun, subject) do
    case apply_fun.(subject) do
      {:ok, result} -> {:ok, result}
      _other -> :no_machinery
    end
  rescue
    _error -> :no_machinery
  catch
    _kind, _reason -> :no_machinery
  end
end
