defmodule AshA2A.Semantic.BoundedProduction do
  @moduledoc """
  RFC S72: a production operation MUST NOT require solving an
  unrestricted "continue reasoning until you believe you are done".
  Known production work reduces to a bounded formal contract.

  This module is that check, made executable. A production operation is
  admitted only as a `%BoundedProduction{}` carrying three real bounds:

    * `max_steps` -- a positive integer step ceiling.
    * `max_wall_time_ms` -- a positive integer wall-clock ceiling,
      measured with `System.monotonic_time/1`, not trusted from a caller.
    * `termination` -- a real 1-arity predicate over the operation
      state. Not an atom, not a description, not a model's judgment.

  `contract/2` refuses, with `:unbounded_production_operation`, any spec
  whose termination is the model's own sense of completion
  (`:model_judgment`, `:until_done`, `:until_believed_complete`,
  `:until_satisfied`, `:none`, `nil`) or a bare string/atom rather than a
  real predicate. That refusal is the whole point: "reason until you
  think you're finished" is not a contract, and the system must be unable
  to accept one.

  `run/3` is the real bounded executor. It terminates in one of exactly
  three ways, all of them decidable from outside the operation:

    * `{:ok, :terminated, state, steps}` -- the predicate became true.
    * `{:error, %{code: :bound_reached, bound: :max_steps, ...}}`
    * `{:error, %{code: :bound_reached, bound: :max_wall_time_ms, ...}}`

  There is no fourth outcome and no unbounded branch, so an operation
  whose predicate never becomes true still halts -- provably, against a
  real never-satisfied predicate, in this module's own test file.

  ## Relationship to `AshA2A.Semantic.Allocator`

  The allocator bounds *what a resolution may spend*; this bounds *how
  long a production operation may run*. They are complementary and
  deliberately separate: an operation can be inside budget and still be
  an unbounded reasoning loop, which is the exact shape RFC S72 refuses.
  """

  @enforce_keys [:operation, :max_steps, :max_wall_time_ms, :termination, :fingerprint]
  defstruct [:operation, :max_steps, :max_wall_time_ms, :termination, :fingerprint]

  @type t :: %__MODULE__{
          operation: String.t(),
          max_steps: pos_integer(),
          max_wall_time_ms: pos_integer(),
          termination: (term() -> boolean()),
          fingerprint: String.t()
        }

  # Terminations that are a model's own sense of completion rather than a
  # decidable predicate. Every one of these is refused by name so the
  # refusal reads as the RFC clause it enforces.
  @unbounded_terminations [
    :model_judgment,
    :until_done,
    :until_believed_complete,
    :until_satisfied,
    :none,
    nil
  ]

  @doc "The named unbounded terminations `contract/2` refuses by construction."
  @spec unbounded_terminations() :: [atom() | nil]
  def unbounded_terminations, do: @unbounded_terminations

  @doc """
  Builds a bounded production contract, or refuses the spec.

  Options (all required, none defaulted -- a defaulted bound is a bound
  the caller never actually stated):

    * `:max_steps` -- positive integer.
    * `:max_wall_time_ms` -- positive integer.
    * `:termination` -- a real 1-arity predicate over state.
  """
  @spec contract(String.t(), keyword()) :: {:ok, t()} | {:error, map()}
  def contract(operation, opts) when is_binary(operation) do
    max_steps = Keyword.get(opts, :max_steps)
    max_wall_time_ms = Keyword.get(opts, :max_wall_time_ms)
    termination = Keyword.get(opts, :termination)

    with :ok <- validate_termination(operation, termination),
         :ok <- validate_bound(operation, :max_steps, max_steps),
         :ok <- validate_bound(operation, :max_wall_time_ms, max_wall_time_ms) do
      contract = %__MODULE__{
        operation: operation,
        max_steps: max_steps,
        max_wall_time_ms: max_wall_time_ms,
        termination: termination,
        fingerprint: ""
      }

      {:ok,
       %{
         contract
         | fingerprint: fingerprint({operation, max_steps, max_wall_time_ms})
       }}
    end
  end

  @doc """
  Real bounded execution of `contract` over `state`.

  `step_fun` is a real 1-arity function from state to next state. The
  termination predicate is checked against the *initial* state first (a
  contract whose goal already holds performs zero steps), then after
  every step. Wall time is re-measured before each step, so a slow
  `step_fun` cannot overrun `max_wall_time_ms` by more than one step's
  duration.
  """
  @spec run(t(), (term() -> term()), term()) ::
          {:ok, :terminated, term(), non_neg_integer()} | {:error, map()}
  def run(%__MODULE__{} = contract, step_fun, state) when is_function(step_fun, 1) do
    loop(contract, step_fun, state, 0, System.monotonic_time(:millisecond))
  end

  defp loop(contract, step_fun, state, steps, started_at_ms) do
    cond do
      contract.termination.(state) ->
        {:ok, :terminated, state, steps}

      steps >= contract.max_steps ->
        {:error,
         %{
           code: :bound_reached,
           bound: :max_steps,
           operation: contract.operation,
           limit: contract.max_steps,
           steps: steps
         }}

      System.monotonic_time(:millisecond) - started_at_ms > contract.max_wall_time_ms ->
        {:error,
         %{
           code: :bound_reached,
           bound: :max_wall_time_ms,
           operation: contract.operation,
           limit: contract.max_wall_time_ms,
           elapsed_ms: System.monotonic_time(:millisecond) - started_at_ms,
           steps: steps
         }}

      true ->
        loop(contract, step_fun, step_fun.(state), steps + 1, started_at_ms)
    end
  end

  defp validate_termination(operation, termination) when is_function(termination, 1) do
    _ = operation
    :ok
  end

  defp validate_termination(operation, termination) when termination in @unbounded_terminations do
    {:error,
     %{
       code: :unbounded_production_operation,
       operation: operation,
       termination: termination,
       detail:
         "RFC S72: a production operation may not require 'continue reasoning until you " <>
           "believe you are done'; supply a real 1-arity termination predicate"
     }}
  end

  defp validate_termination(operation, termination) do
    {:error,
     %{
       code: :unbounded_production_operation,
       operation: operation,
       termination: termination,
       detail: "termination must be a real 1-arity predicate over state, not a description"
     }}
  end

  defp validate_bound(_operation, _name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_bound(operation, name, value) do
    {:error,
     %{
       code: :unbounded_production_operation,
       operation: operation,
       bound: name,
       value: value,
       detail: "#{name} must be a positive integer; an absent bound is not a bound"
     }}
  end

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
