defmodule AshA2A.Execution.PPlan do
  @moduledoc """
  ash_pplan-backed execution adapter for async A2A task dispatch, mirroring
  `AshA2A.Execution.FLAME`'s adapter shape: probe-first `available?/0`
  (`Code.ensure_loaded?/1` — `:ash_pplan` is an optional `only: :test`
  dependency, so this module compiles and loads without it), provider modules
  held as atoms and invoked through `apply/3`, and observed provider evidence
  via `AshA2A.RuntimeReceipt` only.

  FLAME chooses *where* a closure runs; this adapter chooses *what* runs: the
  async skill dispatch's execution record is a durable ash_pplan run keyed by
  the A2A task id, not a node-local handler. The A2A task-id ↔ run binding
  survives by construction — the run id IS the task id:

    * a fresh task id starts (or adopts) the run and attempts it once;
    * a follow-up message with the same task id resumes the SAME run (its
      payload delivered as the parked Await step's consume-once signal);
    * a still-working (deadline-parked) run is passed through untouched —
      never re-attempted through a message, never reported `:input_required`.

  Selection: `execution: [adapter: :pplan, pplan: [...]]` in `use AshA2A.Agent`
  opts (or the app-env `:execution` config). `AshA2A.Transport.Runtime` routes
  the task through this adapter instead of spawning the node-local handler
  worker.

  ## Configuration

      use AshA2A.Agent,
        resource_or_domain: MyDomain,
        execution: [
          adapter: :pplan,
          pplan: [
            store: ...,         # required — host-owned durable store (pid or
                                #   registered name, e.g. a started
                                #   AshPPlan.Reactor.Durable.Store.Dets)
            model: ...,         # required — %AshPPlan.Workflow.Model{}
            bindings: ...,      # required — %{task => %AshPPlan.Realization{}}
            store_module: ...,  # optional — passthrough
            inputs: ...,        # optional — dispatch inputs; DEFAULT is the
                                #   dispatch message's own data-payload merge
            context/plan_iri/intent/signal: ...  # optional passthrough
          ]
        ]

  Every opt value may be `{m, f, a}` (module-atom MFA), resolved on each call
  so a runtime-built store/model/bindings can be referenced from compile-time
  agent opts.

  ## Boundary (named honestly, nothing faked)

    * The plan steps executed inside the durable run are host-admitted plan
      bindings (`AshPPlan.Realization`), not Ash skills — the CommandBus
      admission/replay fence (which FLAME's closure deliberately re-enters)
      does not apply inside a plan run. Coordination evidence is the
      `AshA2A.RuntimeReceipt` (:observed standing only); the durable run's own
      checkpoint tape is the execution record.
    * A2A `tasks/cancel` on a task parked on this adapter transitions the A2A
      task but does NOT cancel the durable run (no cancel wiring on this
      path); cancel the run through `AshA2A.Providers.PPlan.cancel/2`.
    * A `:working` (deadline-parked) run maps to a non-terminal `:working`
      A2A task; a follow-up message on it is refused `:task_in_progress` —
      resumption of a polling run is the engine's job, not a message's.
    * `AshA2A.Providers.PPlan`'s own named gaps (no first-class
      input-required, inputs bound at start only, no `:auth_required`/
      `:rejected` counterpart) apply unchanged here.

  ## Falsifier

  Falsified if any of these hold on a real stack: a dispatch through the
  adapter executes any node-local handler (`handle_message` never runs); a
  follow-up message with the same task id starts a second run instead of
  resuming the first; the durable run's checkpoint tape is not the execution
  record (no tape entries for executed plan steps).
  """

  alias AshA2A.RuntimeReceipt

  @provider AshA2A.Providers.PPlan

  @typedoc "A2A task state returned by `AshA2A.Providers.PPlan`."
  @type state :: :submitted | :working | :input_required | :completed | :failed | :canceled

  @doc """
  Whether the ash_pplan execution backend is loaded.

  `false` in envs where `:ash_pplan` is not a dependency; `AshA2A.Transport.Runtime`
  fails closed with `{:error, {:unsupported, :ash_pplan}}` rather than raising.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@provider)

  @doc """
  Dispatch-or-resume a durable run for `task_id` (the A2A task id), keyed by
  the A2A task id.

  `execution_config` is the effective execution config (`AshA2A.Transport.Runtime.config/1`);
  the `:pplan` key carries the adapter opts (see the moduledoc). Returns
  `{:ok, %{state: state, detail: detail, placement: receipt}}` where `state`/
  `detail` are `AshA2A.Providers.PPlan`'s mapped A2A state and detail, and
  `placement` is the observed `AshA2A.RuntimeReceipt` for the provider call.
  """
  @spec run(String.t(), AshA2A.Protocol.Message.t(), keyword()) ::
          {:ok, %{state: state(), detail: term(), placement: RuntimeReceipt.t()}}
          | {:error, %{reason: term(), placement: RuntimeReceipt.t()}}
          | {:error, {:unsupported, :ash_pplan}}
  def run(task_id, %AshA2A.Protocol.Message{} = message, execution_config) when is_binary(task_id) do
    if available?() do
      with {:ok, opts} <- pplan_opts(execution_config) do
        result = dispatch_or_resume(task_id, message, opts)
        placement = RuntimeReceipt.new(:pplan, :call, task_id, result, metadata: metadata(opts))

        case result do
          {:ok, state, detail} ->
            {:ok, %{state: state, detail: detail, placement: placement}}

          {:error, reason} ->
            {:error, %{reason: reason, placement: placement}}
        end
      end
    else
      # typed, mirror `AshA2A.Execution.FLAME`'s fail-closed probe shape
      {:error, {:unsupported, :ash_pplan}}
    end
  end

  # The binding-survival core: probe the run for this task id, then either
  # adopt+attempt a fresh run, resume a parked one, or pass a still-running /
  # sealed one through untouched.
  defp dispatch_or_resume(task_id, message, opts) do
    payload = message_payload(message)

    case @provider.status(task_id, opts) do
      # no run yet (or a pending record never attempted): start-or-adopt, then
      # one attempt. Dispatch inputs default to the dispatch message's payload.
      probe
      when probe == {:error, :no_such_run} or
             (tuple_size(probe) == 3 and elem(probe, 0) == :ok and elem(probe, 1) == :submitted) ->
        with {:ok, model} <- required_opt(opts, :model),
             {:ok, bindings} <- required_opt(opts, :bindings) do
          inputs = Keyword.get(opts, :inputs, payload)
          @provider.dispatch(task_id, model, bindings, Keyword.put(opts, :inputs, inputs))
        end

      # parked on an Await step: the follow-up payload IS the resume signal.
      {:ok, :input_required, _waiters} ->
        @provider.resume(task_id, payload, opts)

      # deadline-parked (polling): a message cannot resume it (the provider
      # would refuse :no_signal_waiter); pass through untouched.
      {:ok, :working, _detail} = working ->
        working

      # terminal: the sealed state is the standing goal state — return it
      # unchanged, never re-dispatch (idempotence across the binding).
      {:ok, _terminal_state, _detail} = sealed ->
        sealed
    end
  end

  # -- internals --------------------------------------------------------------

  defp pplan_opts(execution_config) do
    case Keyword.get(execution_config, :pplan) do
      opts when is_list(opts) ->
        # every opt value may be {m, f, a}, resolved here so a runtime-built
        # store/model/bindings is reachable from compile-time agent opts
        {:ok, Keyword.new(opts, fn {key, value} -> {key, resolve_value(value)} end)}

      nil ->
        {:error, {:missing_opt, :pplan}}

      other ->
        {:error, {:invalid_opt, {:pplan, other}}}
    end
  end

  defp resolve_value({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: apply(m, f, a)
  defp resolve_value(value), do: value

  defp required_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error, {:missing_opt, key}}
    end
  end

  # Same data-payload merge `AshA2A.Agent` performs for dispatch input.
  defp message_payload(%AshA2A.Protocol.Message{parts: parts}) do
    Enum.reduce(parts, %{}, fn
      %AshA2A.Protocol.Part.Data{data: data}, acc when is_map(data) -> Map.merge(acc, data)
      _other, acc -> acc
    end)
  end

  defp metadata(opts) do
    case opts[:store] do
      nil -> %{}
      store -> %{store: inspect(store)}
    end
  end
end
