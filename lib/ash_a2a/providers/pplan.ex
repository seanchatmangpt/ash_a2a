defmodule AshA2A.Providers.PPlan do
  @moduledoc """
  ash_pplan-backed durability provider for async / multi-turn A2A skill dispatch.

  Given an async skill dispatch (`execution: [mode: :async]`-style), this module
  creates a durable plan-execution record in ash_pplan keyed by the A2A task id,
  so a follow-up message with the same task id resumes the SAME run instead of
  starting a second one. It maps ash_pplan's run lifecycle onto A2A task states:

  | ash_pplan run status | A2A task state |
  |----------------------|----------------|
  | `:pending`           | `:submitted`   |
  | `:waiting`           | `:input_required` |
  | `:polling`           | `:working`     |
  | `:unwinding` / `:cancelling` / `:unwind_blocked` | `:working` |
  | `:completed`         | `:completed`   |
  | `:failed`            | `:failed`      |
  | `:cancelled`         | `:canceled`    |

  ## Semantics

    * `dispatch/4` is start-or-adopt: ash_pplan's `Engine.start/3` is idempotent
      by run id, so re-dispatching the same task id adopts the existing run
      unchanged — never a duplicate execution; sealed checkpoints replay.
    * `resume/3` is the multi-turn hop: it delivers the follow-up payload as a
      consume-once signal to the run's parked signal waiter and attempts once.
      A2A `:input_required` exists here exactly when the plan contains an Await
      step that parks the run in `:waiting`.
    * `status/2` is read-only; `cancel/2` cancels from `:pending`/`:waiting`/
      `:polling` via `Engine.cancel/3` (claim-CAS against in-flight attempts).

  ## Gaps (named honestly, nothing faked)

    * ash_pplan has no dedicated input-required concept. `:input_required` here
      is parked status `:waiting` — a signal waiter. A plan without an Await
      step can never park that way; dispatch of such a plan returns
      `:completed`/`:failed` in one hop. [UNSUPPORTED-capability:
      ash_pplan input-required-as-first-class-status]
    * Run `inputs` are bound at start only: `Engine.start/3` returns existing
      runs unchanged, so a follow-up message's payload reaches the plan ONLY as
      a `resume/3` signal — never by re-dispatch with new inputs.
    * A2A `:auth_required` and `:rejected` have no ash_pplan counterpart and
      are never produced by this provider.
    * Rollback states (`:unwinding`, `:cancelling`, `:unwind_blocked`) surface
      as `:working`; A2A states cannot distinguish them. Read `status/2`'s
      detail map for the underlying run status.
    * The durable store process is host-owned: `:store` is a required opt (the
      pid or registered name of a started `AshPPlan.Reactor.Durable.Store`).
      This module starts no processes.

  ## Configuration seam

  This module is the TASK DURABILITY seam to ash_pplan — the only wrapper of
  `AshPPlan.Reactor.Durable.Engine`'s start/attempt/signal/fetch/cancel on the
  provider path. The replan candidate-policy seam
  (`AshA2A.Replan.Port.AshPPlan`) is separate and Engine-free; see
  `docs/explanation/pplan-seams.md` for the division and why the two are not
  merged.

  The installer (`mix ash_a2a.install --with-pplan`) names this module in
  `config :ash_a2a, :providers, [AshA2A.Providers.PPlan]`. It is referenced by
  name only; nothing on the production DO path calls it. Consistent with that,
  `AshA2A.Semantic.Conformance.llm_module?/1` classifies every
  `AshA2A.Providers.*` module as LLM-bearing and OFF the DO path, so — like
  `AshA2A.Replan.Port.AshPPlan` — every ash_pplan module here is held as a
  runtime atom and invoked through `apply/3` (runtime-value call sites). With
  `:ash_pplan` an optional dependency, the module must also compile and load
  in envs where ash_pplan is absent (`available?/0` is the gate).

  ## Falsifier

  This module is falsified if any of these hold on a real store:

    1. `dispatch/4` twice with the same task id grows the checkpoint tape or
       re-executes any plan step (double execution).
    2. `resume/3` on an `:input_required` run does not consume exactly one
       pending signal (a second `resume/3` consumes nothing yet still moves
       the state), or the delivered payload reaches the plan as anything other
       than the Await step's output.
    3. A run parked on a deadline (`:polling`) is reported `:input_required` —
       that would make the provider lie about who must act next.
  """

  alias AshA2A.Protocol.Task

  # ash_pplan is an optional (`only: :test`) dependency. Like
  # `AshA2A.Replan.Port.AshPPlan` (@owner_provider) and `AshA2A.Execution.FLAME`
  # (ensure_loaded? + apply), every ash_pplan module is held as an atom and
  # invoked through `apply/3`, so this module compiles and loads without it.
  @engine AshPPlan.Reactor.Durable.Engine
  @run AshPPlan.Reactor.Durable.Run
  @status AshPPlan.Reactor.Durable.Status

  @type state :: Task.state()
  @type store :: term()
  @type detail :: term()

  @doc """
  Whether the ash_pplan durability backend is loaded.

  `false` in envs where `:ash_pplan` is not a dependency (it is `only: :test`
  in ash_a2a's own mix.exs); every entry point fails closed with
  `{:error, {:unsupported, :ash_pplan}}` rather than raising.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@engine)

  @doc """
  Start (or adopt) a durable run for `task_id` and attempt it once.

  * `task_id` — the A2A task id; doubles as the durable run id. Idempotent: an
    existing run is adopted unchanged.
  * `model` — an `AshPPlan.Workflow.Model` (built by the caller; this module
    does not invent plans).
  * `bindings` — `%{task_id => AshPPlan.Realization{}}` realizing every model
    task; an unbound task is refused by ash_pplan's projector, not defaulted.
  * `:store` — required, host-owned durable store (pid or registered name).
  * `:inputs` — map of run inputs (default `%{}`), wrapped as `%{input: inputs}`.
  * `:context` — run context map (default `%{}`).
  * `:plan_iri` / `:intent` — optional record fields passed through.

  Returns `{:ok, state, detail}` with `state` one of `:submitted`, `:working`,
  `:input_required`, `:completed`, `:failed`, `:canceled`; `{:error, ...}` is
  reserved for provider-level failure (backend unavailable, missing `:store`).
  `detail` is the sealed result for `:completed`, the failure reason for
  `:failed`, the parked signal-waiter names for `:input_required`, and
  `:claim_held` for `:working` when another attempt holds the claim.
  """
  @spec dispatch(term(), term(), map(), keyword()) :: {:ok, state(), detail()} | {:error, term()}
  def dispatch(task_id, model, bindings, opts \\ []) when is_binary(task_id) and is_map(bindings),
    do: run_dispatch(task_id, model, bindings, opts)

  defp run_dispatch(task_id, model, bindings, opts) do
    if available?() do
      with {:ok, store} <- fetch_store(opts) do
        attrs =
          %{
            id: task_id,
            model: model,
            bindings: bindings,
            inputs: wrap_inputs(Keyword.get(opts, :inputs, %{})),
            context: Keyword.get(opts, :context, %{})
          }
          |> maybe_put(:plan_iri, opts[:plan_iri])
          |> maybe_put(:intent, opts[:intent])

        {:ok, _record} = apply(@engine, :start, [store, attrs, store_opts(opts)])
        attempt_state(task_id, store, opts)
      end
    else
      {:error, {:unsupported, :ash_pplan}}
    end
  end

  # One claimed attempt, mapped to A2A state.
  defp attempt_state(task_id, store, opts) do
    case apply(@engine, :attempt, [store, task_id, store_opts(opts)]) do
      {:completed, result} -> {:ok, :completed, result}
      {:parked, :waiting} -> {:ok, :input_required, parked_waiters(store, task_id, opts)}
      {:parked, :polling} -> {:ok, :working, nil}
      {:failed, reason} -> {:ok, :failed, reason}
      # Cancel won mid-attempt (or unwind finished): the record is terminal; re-read it.
      {:rolled_back, _ending} -> ended_state(store, task_id, opts)
      # Engine-level policy refusal (attempt opts carry a `:policy` driver): typed, not raised.
      {:refused, reason} -> {:error, {:refused, reason}}
      :taken -> {:ok, :working, :claim_held}
      :ended -> ended_state(store, task_id, opts)
      :not_found -> {:error, :no_such_run}
    end
  end

  @doc """
  Deliver a follow-up message payload to a run and attempt it once.

  The payload becomes a consume-once signal. The signal name is the `:signal`
  opt or, unset, the name of the run's parked signal waiter — so the payload
  lands on the Await step that actually parked. An already-terminal run accepts
  no signal; its sealed state is returned unchanged.
  """
  @spec resume(term(), term(), keyword()) :: {:ok, state(), detail()} | {:error, term()}
  def resume(task_id, payload, opts \\ []) when is_binary(task_id) do
    if available?() do
      with {:ok, store} <- fetch_store(opts),
           {:ok, record} <- fetch_record(store, task_id, opts) do
        if apply(@status, :terminal?, [record.status]) do
          {:ok, to_state!(record.status), record.result}
        else
          with {:ok, name} <- signal_name(store, task_id, opts),
               {:ok, _signal} <-
                 apply(@engine, :signal, [store, task_id, name, payload, store_opts(opts)]) do
            attempt_state(task_id, store, opts)
          end
        end
      end
    else
      {:error, {:unsupported, :ash_pplan}}
    end
  end

  @doc """
  Read-only current state of a run, without attempting it.

  Returns `{:ok, state, detail}` where `detail` carries the underlying run
  status, result, error, version, and parked signal-waiter names.
  """
  @spec status(term(), keyword()) :: {:ok, state(), detail()} | {:error, term()}
  def status(task_id, opts \\ []) when is_binary(task_id) do
    if available?() do
      with {:ok, store} <- fetch_store(opts),
           {:ok, record} <- fetch_record(store, task_id, opts) do
        waiters = parked_waiters(store, task_id, opts)

        {:ok, to_state!(record.status),
         %{
           run_status: record.status,
           result: record.result,
           error: record.error,
           version: record.version,
           waiters: waiters
         }}
      end
    else
      {:error, {:unsupported, :ash_pplan}}
    end
  end

  @doc """
  Cancel a run (from `:pending` / `:waiting` / `:polling`).

  Returns `{:ok, :canceled, record}` on success; on `:not_cancellable` the
  run's current (terminal or rolling-back) state is returned instead of an
  error, since the caller's goal state is already standing.
  """
  @spec cancel(term(), keyword()) :: {:ok, state(), detail()} | {:error, term()}
  def cancel(task_id, opts \\ []) when is_binary(task_id) do
    if available?() do
      with {:ok, store} <- fetch_store(opts) do
        case apply(@engine, :cancel, [store, task_id, store_opts(opts)]) do
          {:ok, record} -> {:ok, :canceled, record}
          {:error, :not_cancellable} -> ended_state(store, task_id, opts)
          {:error, _} = error -> error
        end
      end
    else
      {:error, {:unsupported, :ash_pplan}}
    end
  end

  @doc """
  Map an ash_pplan run status atom to an A2A task state (see the moduledoc
  table). Returns `{:error, {:unmapped_status, s}}` for anything outside
  ash_pplan's closed status set — never a silent default.
  """
  @spec to_state(atom()) :: {:ok, state()} | {:error, {:unmapped_status, atom()}}
  def to_state(:pending), do: {:ok, :submitted}
  def to_state(:waiting), do: {:ok, :input_required}
  def to_state(:polling), do: {:ok, :working}
  def to_state(:unwinding), do: {:ok, :working}
  def to_state(:cancelling), do: {:ok, :working}
  def to_state(:unwind_blocked), do: {:ok, :working}
  def to_state(:completed), do: {:ok, :completed}
  def to_state(:failed), do: {:ok, :failed}
  def to_state(:cancelled), do: {:ok, :canceled}
  def to_state(other), do: {:error, {:unmapped_status, other}}

  # -- internals ---------------------------------------------------------------

  defp ended_state(store, task_id, opts) do
    case fetch_record(store, task_id, opts) do
      {:ok, record} -> {:ok, to_state!(record.status), record.result}
      {:error, _} = error -> error
    end
  end

  defp fetch_record(store, task_id, opts) do
    case apply(@engine, :fetch, [store, task_id, store_opts(opts)]) do
      # typed, so a with-chain on it falls through as {:error, :no_such_run}, never a bare :error
      nil -> {:error, :no_such_run}
      record -> {:ok, record}
    end
  end

  defp to_state!(status) do
    case to_state(status) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "unmapped ash_pplan run status: #{inspect(reason)}"
    end
  end

  # The resume signal name: explicit opt wins; else the single parked signal
  # waiter's name; else a typed refusal (never a guessed broadcast).
  defp signal_name(store, task_id, opts) do
    case opts[:signal] do
      nil ->
        case parked_waiters(store, task_id, opts) do
          [name] -> {:ok, name}
          [] -> {:error, :no_signal_waiter}
          names -> {:error, {:ambiguous_waiters, names}}
        end

      name when is_binary(name) ->
        {:ok, name}

      other ->
        {:error, {:invalid_signal, other}}
    end
  end

  # Names of the run's parked signal waiters, read from the real store.
  # `:unknown` when the store module predates `waiters/2` — reported, not faked.
  defp parked_waiters(store, task_id, opts) do
    store_mod = apply(@run, :store_module, [store_opts(opts)])

    if function_exported?(store_mod, :waiters, 2) do
      store_mod.waiters(store, task_id)
      |> Enum.filter(&(&1.kind == :signal))
      |> Enum.map(& &1.name)
    else
      :unknown
    end
  end

  defp fetch_store(opts) do
    case opts[:store] do
      nil -> {:error, {:missing_opt, :store}}
      store -> {:ok, store}
    end
  end

  defp store_opts(opts), do: Keyword.take(opts, [:store_module])

  defp wrap_inputs(%{input: _} = inputs), do: inputs
  defp wrap_inputs(inputs) when is_map(inputs), do: %{input: inputs}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
