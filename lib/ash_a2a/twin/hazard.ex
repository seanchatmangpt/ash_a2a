defmodule AshA2A.Twin.Hazard do
  @moduledoc """
  Statistical hazard monitor for the Communicating Digital Twins subsystem.

  Robust median (tilde-mu) / MAD estimation over a ring buffer of latency
  observations, hazard Z-score `Z = (t - median) / MAD`, trip decision at a
  configurable threshold (default 2.5, strictly greater).

  Semantics mirror the manufactured `latency-hazard-radar` pack (median of
  absolute deviations from the median; average-of-two-middle for even length;
  `MAD == 0` -> `{:error, :insufficient_dispersion}`), reimplemented here so
  the twin namespace has no cross-pack dependency.

  Zero dispersion (`MAD == 0`) leaves z undefined, so `zscore/2` and
  `observe/2` return `{:error, :insufficient_dispersion}`; callers decide the
  policy. `zero_dispersion_spike/2` is the fail-closed helper: a slow
  observation against an established flat window is a spike, not silence.
  """

  alias AshA2A.Twin.Hazard

  @enforce_keys [:buffer, :capacity]
  defstruct buffer: [], capacity: 64

  @type t :: %Hazard{buffer: [number()], capacity: pos_integer()}

  @default_threshold 2.5
  @default_capacity 64

  @doc "Default hazard threshold (Z-score above which a hazard trips)."
  @spec default_threshold :: float()
  def default_threshold, do: @default_threshold

  @doc "Default ring-buffer capacity for the observation window."
  @spec default_capacity :: 64
  def default_capacity, do: @default_capacity

  @doc "New hazard monitor with a ring buffer of the given capacity."
  @spec new(pos_integer()) :: Hazard.t()
  def new(capacity \\ @default_capacity)

  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %Hazard{buffer: [], capacity: capacity}
  end

  def new(other),
    do: raise(ArgumentError, "hazard capacity must be a positive integer, got: #{inspect(other)}")

  @doc """
  Push a latency observation onto the ring buffer.

  Older observations fall off once capacity is reached (oldest evicted first).
  Raises `FunctionClauseError` for a non-number observation.
  """
  @spec push(Hazard.t(), number()) :: Hazard.t()
  def push(%Hazard{buffer: buffer, capacity: cap} = h, x) when is_number(x) do
    %{h | buffer: Enum.take([x | buffer], cap)}
  end

  @doc "Current observation window (most recent first)."
  @spec window(Hazard.t()) :: [number()]
  def window(%Hazard{buffer: buffer}), do: buffer

  @doc """
  Observe a latency against the monitor's window: estimate against the
  pre-observation window (reference-pack semantics: `zscore(t, window)` is
  computed on the window as it stood BEFORE this observation), then push the
  observation so the window advances.

  Returns `{:ok, %{z, median, mad, trip?, window, monitor}}`,
  `{:error, :insufficient_dispersion}` when MAD = 0, or
  `{:error, :invalid_observation}` for a non-number. The error paths return
  no monitor and do NOT push: the caller owns the push (`push/2`) so a
  zero-dispersion window can heal on its own terms.
  """
  @spec observe(Hazard.t(), term()) ::
          {:ok, map()} | {:error, :insufficient_dispersion | :invalid_observation}
  def observe(%Hazard{} = h, x) when is_number(x) do
    case zscore(x, h.buffer) do
      {:ok, z} ->
        h2 = push(h, x)

        {:ok,
         %{
           z: z,
           median: median(h.buffer),
           mad: mad(h.buffer),
           trip?: trip?(z),
           window: h.buffer,
           monitor: h2
         }}

      {:error, _} = err ->
        err
    end
  end

  def observe(%Hazard{}, _x), do: {:error, :invalid_observation}

  @doc """
  Fail-closed zero-dispersion policy: `{:spike, stats}` when `window` has at
  least 3 samples, MAD is 0 and `x` exceeds the (flat) median; else `:none`.
  Only slow observations spike — latency hazards are one-sided.
  """
  @spec zero_dispersion_spike([number()], term()) :: {:spike, map()} | :none
  def zero_dispersion_spike(window, x) when is_list(window) and is_number(x) do
    if length(window) >= 3 and mad(window) == 0 and x > median(window) do
      {:spike,
       %{
         z: :infinity,
         median: median(window),
         mad: 0.0,
         trip?: true,
         window: window,
         dispersion: :zero
       }}
    else
      :none
    end
  end

  def zero_dispersion_spike(_window, _x), do: :none

  @doc """
  Hazard Z-score over a window: `Z = (x - median(window)) / MAD(window)`.

  Returns `{:error, :insufficient_dispersion}` when MAD = 0 (zero-dispersion
  or empty window).
  """
  @spec zscore(term(), term()) ::
          {:ok, float()} | {:error, :insufficient_dispersion | :invalid_observation}
  def zscore(x, window) when is_number(x) and is_list(window) do
    case mad(window) do
      d when d == 0.0 or d == 0 -> {:error, :insufficient_dispersion}
      d -> {:ok, (x - median(window)) / d}
    end
  end

  def zscore(_x, _window), do: {:error, :invalid_observation}

  @doc """
  Trip decision: true when z exceeds threshold (strictly greater).

  Threshold may be a sigma multiple (default 2.5) or, for hours-before-SLA
  semantics, any absolute number in the caller's unit (e.g. seconds).
  """
  @spec trip?(number(), number()) :: boolean()
  def trip?(z, threshold \\ @default_threshold) when is_number(z) and is_number(threshold) do
    z > threshold
  end

  @doc """
  Median of a numeric list (average of two middle values for even length).
  Raises `ArgumentError` on an empty list.
  """
  @spec median([number()]) :: float()
  def median([]), do: raise(ArgumentError, "median of empty window")

  def median(list) when is_list(list) do
    sorted = Enum.sort(list)
    n = length(sorted)

    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2)) * 1.0
    else
      (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
    end
  end

  @doc "Median absolute deviation (0.0 for an empty or zero-dispersion window)."
  @spec mad([number()]) :: float()
  def mad([]), do: 0.0

  def mad(list) when is_list(list) do
    m = median(list)
    list |> Enum.map(fn x -> abs(x - m) end) |> median()
  end
end
