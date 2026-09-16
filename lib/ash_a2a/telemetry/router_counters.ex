defmodule AshA2A.Telemetry.RouterCounters do
  @moduledoc """
  Real in-process aggregator answering, for a real running deployment: "how
  many requests took the deterministic (facts) path vs. the structured-
  phrase path vs. the LLM (text) path through
  `AshA2A.Planning.RequestRouter.route/3`?" -- the concrete, buildable
  instrument for impossible-item #6 (this codebase cannot know a real
  Fortune-5 deployment's actual tier split; it can build, and this module
  is, the real counter that would measure it in one).

  ## Mechanism

  Backed by `:counters` (BEAM/OTP's lock-free atomic-counter primitive,
  preloaded since OTP 21.2 -- not a GenServer/Agent mailbox), so
  incrementing never serializes concurrent dispatches through a single
  process: `:telemetry.execute/3` calls every attached handler
  synchronously, in the emitting process itself (the same real mechanism
  `AshA2A.Telemetry.OcelForwarder` and `AshA2A.Agent.__cancel__/2` already
  rely on), and `:counters.add/3` is safe to call from arbitrarily many
  processes at once without a bottleneck.

  Each attached instance owns its own counters reference, threaded through
  as `:telemetry.attach/4`'s own documented `config` argument -- there is
  no global/`:persistent_term` counter here, so multiple independent
  instances (for example, one per `async: true` test process, or one owned
  by a host application) never share state and never interfere with each
  other's counts.

  ## Three slots, one genuinely new (this task)

  Originally two slots (deterministic, llm). This task adds a third,
  genuinely additive `:phrase` slot for `AshA2A.Planning.RequestRouter`'s
  structured-phrase middle tier (`tier: :phrase` events, previously
  silently ignored by this module's own catch-all `handle_event/4` clause
  -- see that module's moduledoc for the "natural, separate follow-on"
  this task completes). `:phrase` is counted separately rather than folded
  into `:deterministic`: a caller can always sum `deterministic + phrase`
  after the fact to recover the old two-way split, but folding at the
  source would make that split unrecoverable. `:deterministic`'s own
  meaning is unchanged by this task -- it still means facts-tier only, so
  no existing caller reading `counts(ref).deterministic` sees a silent
  semantic change; `:phrase` is purely additive to the returned map.

  ## Usage

      ref = AshA2A.Telemetry.RouterCounters.new()
      handler_id = AshA2A.Telemetry.RouterCounters.attach!(ref)
      # ... real dispatch through AshA2A.Planning.RequestRouter.route/3 ...
      AshA2A.Telemetry.RouterCounters.counts(ref)
      #=> %{deterministic: 3, llm: 1, phrase: 2}
      AshA2A.Telemetry.RouterCounters.detach(handler_id)

  A host application wanting one long-lived, application-wide instance
  attaches once (for example from `AshA2A.Application.start/2`, the same
  place `AshA2A.Telemetry.OcelForwarder.attach!/0` is called) and holds the
  returned `ref` wherever it is convenient to query later (config,
  `:persistent_term`, a supervised process's state) -- this module makes
  no assumption about where a caller stores that reference.
  """

  @deterministic_index 1
  @llm_index 2
  @phrase_index 3

  @typedoc "A `:counters` reference returned by `new/0`."
  @type ref :: :counters.counters_ref()

  @doc """
  A fresh, zeroed counters reference (three slots: deterministic, llm,
  phrase). Not yet attached to telemetry -- pair with `attach!/2`.
  """
  @spec new() :: ref()
  def new, do: :counters.new(3, [:atomics])

  @doc """
  Attaches `ref` to `[:ash_a2a, :router, :tier_selected]`: `tier: :facts`
  events increment the deterministic slot, `tier: :text` events increment
  the llm slot, `tier: :phrase` events increment the phrase slot, any
  other metadata shape is ignored (fails closed rather than crashing the
  emitting process). Returns the real `:telemetry` handler id (an opaque
  term) for a later `detach/1` call.

  `handler_id_suffix` defaults to a fresh `make_ref/0` so two independent
  `attach!/1` calls (for example from two concurrent `async: true` tests)
  always get distinct `:telemetry` handler ids and never collide or
  silently overwrite one another's registration -- passing an explicit,
  stable suffix is only needed when a caller wants a predictable, opaque
  handler id of its own (an idempotent boot-time `attach!/2` call, say).
  """
  @spec attach!(ref(), term()) :: term()
  def attach!(ref, handler_id_suffix \\ make_ref()) do
    handler_id = {__MODULE__, handler_id_suffix}

    :ok =
      case :telemetry.attach(
             handler_id,
             [:ash_a2a, :router, :tier_selected],
             &__MODULE__.handle_event/4,
             ref
           ) do
        :ok -> :ok
        {:error, :already_exists} -> :ok
      end

    handler_id
  end

  @doc "Detaches a handler id previously returned by `attach!/2`."
  @spec detach(term()) :: :ok | {:error, :not_found}
  def detach(handler_id), do: :telemetry.detach(handler_id)

  @doc false
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), ref()) ::
          :ok
  def handle_event([:ash_a2a, :router, :tier_selected], _measurements, %{tier: :facts}, ref) do
    :counters.add(ref, @deterministic_index, 1)
  end

  def handle_event([:ash_a2a, :router, :tier_selected], _measurements, %{tier: :text}, ref) do
    :counters.add(ref, @llm_index, 1)
  end

  def handle_event([:ash_a2a, :router, :tier_selected], _measurements, %{tier: :phrase}, ref) do
    :counters.add(ref, @phrase_index, 1)
  end

  def handle_event([:ash_a2a, :router, :tier_selected], _measurements, _metadata, _ref), do: :ok

  @doc """
  Current real atomic counts for `ref`: `%{deterministic: n, llm: n, phrase: n}`.
  """
  @spec counts(ref()) :: %{
          deterministic: non_neg_integer(),
          llm: non_neg_integer(),
          phrase: non_neg_integer()
        }
  def counts(ref) do
    %{
      deterministic: :counters.get(ref, @deterministic_index),
      llm: :counters.get(ref, @llm_index),
      phrase: :counters.get(ref, @phrase_index)
    }
  end
end
