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
  def new(capacity \\ @default_capacity) when is_integer(capacity) and capacity > 0 do
    %Hazard{buffer: [], capacity: capacity}
  end

  @doc """
  Push a latency observation onto the ring buffer.

  Older observations fall off once capacity is reached (oldest evicted first).
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

  Returns `{:ok, %{z, median, mad, trip?, window, monitor}}` or
  `{:error, :insufficient_dispersion}` when MAD = 0 (the observation is
  still pushed, so a zero-dispersion window heals).
  """
  @spec observe(Hazard.t(), number()) ::
          {:ok, map()} | {:error, :insufficient_dispersion}
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
        push(h, x)
        err
    end
  end

  @doc """
  Hazard Z-score over a window: `Z = (x - median(window)) / MAD(window)`.

  Returns `{:error, :insufficient_dispersion}` when MAD = 0 (zero-dispersion
  or empty window).
  """
  @spec zscore(number(), [number()]) :: {:ok, float()} | {:error, :insufficient_dispersion}
  def zscore(x, window) when is_number(x) and is_list(window) do
    case mad(window) do
      d when d == 0.0 or d == 0 -> {:error, :insufficient_dispersion}
      d -> {:ok, (x - median(window)) / d}
    end
  end

  @doc """
  Trip decision: true when z exceeds threshold (strictly greater).

  Threshold may be a sigma multiple (default 2.5) or, for hours-before-SLA
  semantics, any absolute number in the caller's unit (e.g. seconds).
  """
  @spec trip?(number(), number()) :: boolean()
  def trip?(z, threshold \\ @default_threshold) when is_number(z) and is_number(threshold) do
    z > threshold
  end

  @doc "Median of a numeric list (average of two middle values for even length)."
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
