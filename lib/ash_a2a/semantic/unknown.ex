defmodule AshA2A.Semantic.Unknown do
  @moduledoc """
  RFC S36/S37/S64: UNKNOWN as an explicit, first-class state.

  UNKNOWN is **not** failure. It means the *admitted machinery is
  insufficient* for this subject: nothing deterministic in the closed
  capability/rule set covers it yet. Failure is a transition that went
  wrong; UNKNOWN is a transition that was never admitted in the first
  place, and the correct response is to allocate bounded resources to
  resolving it -- not to guess, and not to stop.

  ## The invariant this module exists to make structural

  > UNKNOWN MUST NOT silently become DO.

  Enforced three ways, none of which is a runtime policy check:

    1. `%Unknown{}` carries `standing: :unknown, authority: :none` and
       there is no constructor that produces any other standing.
    2. There is no `to_command/1`, no `execute/1`, and no function in
       this module that returns an `AshA2A.Command`. The only "can this
       be executed?" entry point is `admit_for_do/1`, which is a total
       function whose every clause returns `{:error, ...}`.
    3. `route/3` -- the RFC S64 algorithm -- returns either a
       `%Resolution{}` (standing `:candidate`, authority `:none`) or the
       unresolved `%Unknown{}` itself. Neither is executable; reaching
       DO from either still requires the ordinary
       `AshA2A.CommandBus.run/4` path with real admitted authority.

  ## RFC S64 algorithm shape (`route/3`)

      1. Attempt the admitted deterministic machinery for this semantic class.
         -> resolved: emit allocation(class, :machinery); done, zero resolver spend.
      2. Otherwise DECLARE UNKNOWN, explicitly and typed.
      3. Allocate bounded budget for resolution (RFC S38) BEFORE calling anything
         expensive. Exhausted -> stay UNKNOWN. Never "proceed anyway".
      4. Dispatch to a resolver: :llm | :human | :prover | :search
         | :synthesis | :experiment.
      5. The result returns as CANDIDATE, via AshA2A.Semantic.LlmBoundary --
         never as canonical truth, for any resolver kind (RFC S40).
      6. A resolved UNKNOWN SHOULD compile back into reusable machinery
         (AshA2A.Semantic.MachineExperience, RFC S39/S65) so the same semantic
         class takes step 1 next time.

  Step 6 is deliberately the caller's to perform: `route/3` produces the
  candidate, and `MachineExperience.compile_back/4` turns it into
  machinery only when the caller has actually validated it. A resolution
  that auto-installed itself would be the model promoting its own rule
  (RFC S40 effect 5).
  """

  @enforce_keys [:class, :subject, :reason, :fingerprint]
  defstruct [:class, :subject, :reason, :fingerprint, standing: :unknown, authority: :none]

  @type reason ::
          :no_admitted_machinery
          | :insufficient_coverage
          | :ambiguous_semantics
          | :allocation_exhausted
          | :resolver_failed
          | :resolver_refused

  @type resolver_kind :: :llm | :human | :prover | :search | :synthesis | :experiment

  @type t :: %__MODULE__{
          class: String.t(),
          subject: term(),
          reason: reason(),
          fingerprint: String.t(),
          standing: :unknown,
          authority: :none
        }

  @resolver_kinds ~w(llm human prover search synthesis experiment)a

  # Which budget dimension each resolver kind spends. A caller may
  # override per call with `:resolver_dimension`; these are the defaults.
  @resolver_dimensions %{
    llm: :inference_calls,
    human: :external_requests,
    prover: :compute_units,
    search: :compute_units,
    synthesis: :inference_calls,
    experiment: :external_requests
  }

  @allocation_event [:ash_a2a, :semantic, :allocation]

  alias AshA2A.Semantic.Allocator
  alias AshA2A.Semantic.Allocator.Budget
  alias AshA2A.Semantic.LlmBoundary
  alias AshA2A.Semantic.MachineExperience
  alias AshA2A.Semantic.Unknown.Resolution

  @doc "The six resolution routes RFC S37 admits."
  @spec resolver_kinds() :: [resolver_kind()]
  def resolver_kinds, do: @resolver_kinds

  @doc "The telemetry event `route/3` emits at each allocation decision."
  @spec allocation_event() :: [atom()]
  def allocation_event, do: @allocation_event

  @doc """
  Declares an UNKNOWN explicitly. `class` is the semantic class key --
  the thing that will route deterministically once machinery exists for
  it, and the key `AshA2A.Telemetry.AllocationCounters` measures
  `Allocation_LLM(class, t)` against.
  """
  @spec declare(String.t(), term(), reason()) :: t()
  def declare(class, subject, reason \\ :no_admitted_machinery) when is_binary(class) do
    unknown = %__MODULE__{
      class: class,
      subject: subject,
      reason: reason,
      fingerprint: ""
    }

    %{unknown | fingerprint: fingerprint({class, subject, reason})}
  end

  @doc """
  Total function: an UNKNOWN is never admissible for DO, for any reason
  value, ever. This is the codified form of "UNKNOWN MUST NOT silently
  become DO" -- the question is askable, and the answer is always no.

  Note the asymmetry with `AshA2A.CommandBus`: the bus refuses
  `consequence: :unknown` (an unclassified *capability*). This refuses
  an unresolved *semantic subject*. Both roads to "we do not know" end
  in a refusal rather than a dispatch.
  """
  @spec admit_for_do(t()) :: {:error, map()}
  def admit_for_do(%__MODULE__{} = unknown) do
    result =
      {:error,
       %{
         code: :unknown_not_executable,
         detail: "UNKNOWN must not silently become DO; resolve it to a candidate first (RFC S36)",
         class: unknown.class,
         reason: unknown.reason
       }}

    # `[:ash_a2a, :semantic, :unknown, :admit_for_do]`: the DO-admission
    # decision for an UNKNOWN subject, whatever it was (RFC-SA2A-002 §79
    # attempt evidence). Observational only.
    :telemetry.execute([:ash_a2a, :semantic, :unknown, :admit_for_do], %{count: 1}, %{
      class: unknown.class,
      reason: unknown.reason,
      fingerprint: unknown.fingerprint,
      outcome: if(match?({:error, _}, result), do: :refused, else: :admitted),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil))
    })

    result
  end

  @doc """
  RFC S64 algorithm. See the moduledoc for the six numbered steps.

  Options:

    * `:machinery` -- an `AshA2A.Semantic.MachineExperience.Store.t()`
      consulted at step 1. Default: an empty store (so step 1 always
      misses and every subject is genuinely UNKNOWN).
    * `:budget` -- an `AshA2A.Semantic.Allocator.Budget.t()`. Required
      to reach step 4; without one, resolution is refused with
      `:allocation_exhausted` (fail closed -- no budget means no spend,
      never unlimited spend).
    * `:resolver` -- `{kind, fun}` where `kind` is one of
      `resolver_kinds/0` and `fun` is a real 1-arity function taking the
      declared `%Unknown{}` and returning `{:ok, map}` or
      `{:error, term}`. This is a dependency-injection seam of exactly
      the same shape as `AshA2A.Semantic.Compiler`'s `:generate_object`
      -- a real function, never a mock.
    * `:resolver_dimension` -- override the budget dimension this
      resolver spends. Defaults per kind (see moduledoc source).
    * `:resolver_amount` -- how much of that dimension one call costs.
      Default `1`.

  Returns:

    * `{:ok, :machinery, result, budget}` -- step 1 hit. No resolver was
      called and no resolver budget was spent.
    * `{:ok, :resolved, %Resolution{}, budget}` -- steps 2-5 ran. The
      resolution is candidate-standing, authority `:none`.
    * `{:unknown, %Unknown{}, reason_map}` -- still UNKNOWN. The reason
      map names which hop failed. Nothing executable is returned.
  """
  @spec route(String.t(), term(), keyword()) ::
          {:ok, :machinery, term(), Budget.t() | nil}
          | {:ok, :resolved, Resolution.t(), Budget.t()}
          | {:unknown, t(), map()}
  def route(class, subject, opts \\ []) when is_binary(class) do
    store = Keyword.get(opts, :machinery, MachineExperience.new_store())
    budget = Keyword.get(opts, :budget)

    case MachineExperience.resolve(store, class, subject) do
      {:ok, result} ->
        emit_allocation(class, :machinery)
        {:ok, :machinery, result, budget}

      :no_machinery ->
        class
        |> declare(subject, :no_admitted_machinery)
        |> resolve_declared(budget, opts)
    end
  end

  defp resolve_declared(%__MODULE__{} = unknown, budget, opts) do
    case Keyword.get(opts, :resolver) do
      {kind, fun} when kind in @resolver_kinds and is_function(fun, 1) ->
        allocate_then_resolve(unknown, budget, kind, fun, opts)

      nil ->
        {:unknown, unknown,
         %{code: :no_resolver, detail: "UNKNOWN declared and left unresolved, never executed"}}

      other ->
        {:unknown, %{unknown | reason: :resolver_refused},
         %{code: :invalid_resolver, resolver: other}}
    end
  end

  defp allocate_then_resolve(unknown, nil, kind, _fun, _opts) do
    {:unknown, %{unknown | reason: :allocation_exhausted},
     %{
       code: :allocation_exhausted,
       detail: "no budget issued; an unbudgeted resolver call is never made (RFC S38)",
       resolver: kind
     }}
  end

  defp allocate_then_resolve(unknown, %Budget{} = budget, kind, fun, opts) do
    dimension = Keyword.get(opts, :resolver_dimension, Map.fetch!(@resolver_dimensions, kind))
    amount = Keyword.get(opts, :resolver_amount, 1)

    case Allocator.allocate(budget, dimension, amount) do
      {:ok, budget} ->
        run_resolver(unknown, budget, kind, fun)

      {:error, reason} ->
        {:unknown, %{unknown | reason: :allocation_exhausted}, reason}
    end
  end

  defp run_resolver(unknown, budget, kind, fun) do
    case fun.(unknown) do
      {:ok, payload} ->
        emit_allocation(unknown.class, kind)

        case LlmBoundary.candidate(unknown, kind, payload) do
          {:ok, %Resolution{} = resolution} ->
            {:ok, :resolved, resolution, budget}

          {:error, reason} ->
            {:unknown, %{unknown | reason: :resolver_refused}, reason}
        end

      {:error, reason} ->
        emit_allocation(unknown.class, kind)

        {:unknown, %{unknown | reason: :resolver_failed},
         %{code: :resolver_failed, reason: reason}}
    end
  end

  # Emitted at every real allocation decision -- the deterministic
  # (machinery) hit as well as every resolver call, including one whose
  # resolver then failed (the spend happened either way). This is what
  # makes Allocation_LLM(class, t) a measured quantity rather than an
  # asserted one; see AshA2A.Telemetry.AllocationCounters.
  defp emit_allocation(class, resolver) do
    :telemetry.execute(@allocation_event, %{count: 1}, %{class: class, resolver: resolver})
  end

  @doc false
  @spec fingerprint(term()) :: String.t()
  def fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
