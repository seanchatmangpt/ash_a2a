defmodule AshA2A.Chicago.Bench.Timeline do
  @moduledoc """
  Per-iteration phase clock for the RFC-SA2A-002 benchmarks.

  Attaches a `:telemetry` handler to events the real SUT boundaries emit
  (admission stages, grant decision, CommandBus transitions) and stamps each
  with `System.monotonic_time(:microsecond)` in the emitting process, so a
  benchmark can split one end-to-end latency into the phases §85/§89 name
  without instrumenting the SUT beyond the telemetry it already emits.

  This is timing instrumentation, not attempt evidence: standing evidence is
  recorded by the independent `AshA2A.Chicago.Observer` and re-derived from the
  durable OCEL artifact. The handler only `send/2`s to the collecting process
  and never raises, so it cannot perturb or detach itself from the SUT path.
  """

  @metadata_keys [:outcome, :code, :stage, :command_id, :receipt_id, :execution_id]

  @type entry :: %{event: [atom()], at_us: integer(), metadata: map()}

  @doc "Attaches to `events`, delivering entries to the calling process. Returns the collector ref."
  @spec attach([[atom()]]) :: reference()
  def attach(events) when is_list(events) do
    ref = make_ref()

    :ok =
      :telemetry.attach_many({__MODULE__, ref}, events, &__MODULE__.handle_event/4, %{
        pid: self(),
        ref: ref
      })

    ref
  end

  @doc "Detaches the collector and discards anything still undelivered."
  @spec detach(reference()) :: :ok
  def detach(ref) do
    :telemetry.detach({__MODULE__, ref})
    _ = drain(ref)
    :ok
  end

  @doc false
  def handle_event(event, _measurements, metadata, %{pid: pid, ref: ref}) do
    at = System.monotonic_time(:microsecond)
    meta = if is_map(metadata), do: Map.take(metadata, @metadata_keys), else: %{}
    send(pid, {ref, event, at, meta})
    :ok
  end

  @doc "Every entry delivered so far, in emission order (synchronous SUT work)."
  @spec drain(reference()) :: [entry()]
  def drain(ref), do: drain(ref, [])

  defp drain(ref, acc) do
    receive do
      {^ref, event, at, meta} -> drain(ref, [%{event: event, at_us: at, metadata: meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "First entry for `event`, or nil."
  @spec first([entry()], [atom()]) :: entry() | nil
  def first(entries, event), do: Enum.find(entries, &(&1.event == event))

  @doc "Every entry for `event`."
  @spec all([entry()], [atom()]) :: [entry()]
  def all(entries, event), do: Enum.filter(entries, &(&1.event == event))

  @doc "Position of the first `event` entry in emission order, or nil."
  @spec index([entry()], [atom()]) :: non_neg_integer() | nil
  def index(entries, event), do: Enum.find_index(entries, &(&1.event == event))

  @doc "`b.at_us - a.at_us` for two entries (nil when either is missing)."
  @spec gap(entry() | integer() | nil, entry() | integer() | nil) :: integer() | nil
  def gap(nil, _), do: nil
  def gap(_, nil), do: nil
  def gap(%{at_us: a}, b), do: gap(a, b)
  def gap(a, %{at_us: b}), do: gap(a, b)
  def gap(a, b) when is_integer(a) and is_integer(b), do: b - a
end
