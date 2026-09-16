defmodule AshA2A.Chicago.Context do
  @moduledoc """
  Per-run context handed to every `AshA2A.Chicago.Court.run/1`.

  `stimulus/3` is the only sanctioned way for a court to drive the SUT: it
  brackets the stimulus with `[:ash_a2a, :chicago, :stimulus, :start | :stop]`
  telemetry so the independent `AshA2A.Chicago.Observer` attributes every SUT
  event emitted in between to that falsifier. Courts run strictly one at a
  time, so attribution is unambiguous for synchronous SUT work; SUT work that
  outlives the stimulus function is observed but unattributed.

  `observed/2` returns what the observer recorded for a falsifier so far --
  the court's in-run view. The standing verdict is still re-derived from the
  durable OCEL artifact by `AshA2A.Chicago.Query` after the run (§104).
  """

  alias AshA2A.Chicago.{Falsifier, Observer, Profile, Subject}

  @enforce_keys [:run_id, :profile, :subject, :evidence_dir]
  defstruct [:run_id, :profile, :subject, :evidence_dir, :observer, :court, opts: []]

  @type t :: %__MODULE__{
          run_id: String.t(),
          profile: Profile.t(),
          subject: Subject.t(),
          evidence_dir: Path.t(),
          observer: GenServer.server() | nil,
          court: module() | nil,
          opts: keyword()
        }

  @start [:ash_a2a, :chicago, :stimulus, :start]
  @stop [:ash_a2a, :chicago, :stimulus, :stop]

  @spec stimulus_events() :: [[atom()]]
  def stimulus_events, do: [@start, @stop]

  @doc """
  Runs `fun` as the stimulus for `falsifier`, returning `fun`'s value.

  Exceptions, throws and exits propagate after the `:stop` event is emitted
  (with `outcome: :raised`), so a crashing stimulus is still visible evidence.
  """
  @spec stimulus(t(), Falsifier.t(), (-> result)) :: result when result: var
  def stimulus(%__MODULE__{} = ctx, %Falsifier{} = falsifier, fun) when is_function(fun, 0) do
    meta = %{run_id: ctx.run_id, falsifier_id: falsifier.id, court_id: falsifier.court_id}
    :telemetry.execute(@start, %{system_time: System.system_time()}, meta)
    started = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      emit_stop(meta, started, :returned)
      result
    catch
      kind, reason ->
        emit_stop(meta, started, :raised)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Observer records attributed to `falsifier` (or its id) so far in this run."
  @spec observed(t(), Falsifier.t() | String.t()) :: [Observer.record()]
  def observed(%__MODULE__{observer: nil}, _falsifier), do: []
  def observed(%__MODULE__{} = ctx, %Falsifier{id: id}), do: observed(ctx, id)

  def observed(%__MODULE__{observer: observer}, id) when is_binary(id),
    do: Observer.records_for(observer, id)

  @doc "True when the observer saw at least one attributed record of `activity`."
  @spec observed?(t(), Falsifier.t() | String.t(), String.t()) :: boolean()
  def observed?(%__MODULE__{} = ctx, falsifier, activity) when is_binary(activity),
    do: Enum.any?(observed(ctx, falsifier), &(&1.activity == activity))

  defp emit_stop(meta, started, outcome) do
    :telemetry.execute(
      @stop,
      %{
        system_time: System.system_time(),
        duration_us: System.monotonic_time(:microsecond) - started
      },
      Map.put(meta, :outcome, outcome)
    )
  end
end
